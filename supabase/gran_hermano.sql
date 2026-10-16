-- Gran Hermano: votación secreta de los viernes, con desempates.
-- Pegar y ejecutar UNA vez en Supabase → SQL Editor (se puede repetir sin problema).
--
-- Cómo se garantiza el secreto:
--   * "Quién votó" (gh_voted) y "los votos" (gh_tally) se guardan por separado
--     y no hay nada que los una: el conteo es un número por candidato, no un
--     registro por voto, y no guarda ni quién ni cuándo.
--   * Cada voto vuelve a escribir TODAS las filas de la votación en las dos
--     tablas, así ni siquiera las marcas internas de la base de datos permiten
--     cruzar quién votó a quién.
--   * Nadie lee estas tablas directo; los resultados solo salen de gh_state()
--     cuando la votación ya cerró.
--   * Excepción acordada con la banda: en las votaciones creadas desde esta
--     versión (admin_sees = true), el admin puede ver quién votó a quién, y
--     solo cuando la votación ya cerró. La página lo avisa al votar. Las
--     votaciones anteriores siguen siendo secretas para todos.
--
-- Horarios (hora de Argentina):
--   * Se abre sola cada jueves a las 22:00 y se cierra el viernes a las 23:59.
--   * El admin puede abrir una antes o cerrar la abierta cuando quiera.
--   * Si hay empate, se abre un desempate de 24 horas entre los empatados.
--     Si vuelve a empatar, otro desempate.
--
-- La casa: el admin marca a cada integrante como participante (se lo puede
-- votar), inmune, eliminado o fuera del juego. Los participantes son los
-- nominados de cada votación automática. Al cerrar una votación sin empate,
-- el más votado pasa solo a eliminado.

-- ---------- Tablas ----------
create table if not exists public.gh_rounds (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('semanal', 'desempate')),
  week_date date not null,
  parent_id uuid references public.gh_rounds (id) on delete cascade,
  opens_at timestamptz not null,
  closes_at timestamptz not null,
  closed_at timestamptz,
  candidates uuid[] not null,
  eligible int not null,
  tie_handled boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.gh_voted (
  round_id uuid not null references public.gh_rounds (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  touch int not null default 0,
  primary key (round_id, user_id)
);

create table if not exists public.gh_tally (
  round_id uuid not null references public.gh_rounds (id) on delete cascade,
  target uuid not null,
  votes int not null default 0,
  primary key (round_id, target)
);

-- Quiénes pueden votar (vacío = todos los registrados).
alter table public.gh_rounds add column if not exists voters uuid[];

-- Configuración del admin: una sola fila.
create table if not exists public.gh_settings (
  id int primary key default 1 check (id = 1),
  nominees uuid[],
  only_nominees_vote boolean not null default false
);
insert into public.gh_settings (id) values (1) on conflict (id) do nothing;

-- Estado de cada integrante: {"<id>": "participante" | "inmune" | "eliminado"}.
-- Quien no figura, no juega.
alter table public.gh_settings add column if not exists statuses jsonb not null default '{}'::jsonb;

-- Si ya había nominados guardados, pasan a ser participantes.
update public.gh_settings
   set statuses = (select coalesce(jsonb_object_agg(x::text, 'participante'), '{}'::jsonb) from unnest(nominees) as x)
 where id = 1 and statuses = '{}'::jsonb and nominees is not null;

-- Historial de antes de la página (se carga a mano).
create table if not exists public.gh_past (
  id uuid primary key default gen_random_uuid(),
  week int not null unique check (week > 0),
  name text not null check (char_length(name) between 1 and 40)
);
insert into public.gh_past (week, name) values
  (1, 'Jero'), (2, 'Aldi'), (3, 'Agus'), (4, 'Mili')
on conflict (week) do nothing;
alter table public.gh_past enable row level security;
revoke all on public.gh_past from anon, authenticated;

-- ¿El admin puede ver quién votó a quién en esta votación? (las viejas, no)
alter table public.gh_rounds add column if not exists admin_sees boolean not null default false;

-- Registro de votos que ve solo el admin (solo para votaciones con admin_sees).
create table if not exists public.gh_admin_log (
  round_id uuid not null references public.gh_rounds (id) on delete cascade,
  voter uuid not null references auth.users (id) on delete cascade,
  target uuid not null,
  primary key (round_id, voter)
);
alter table public.gh_admin_log enable row level security;
revoke all on public.gh_admin_log from anon, authenticated;

alter table public.gh_rounds enable row level security;
alter table public.gh_settings enable row level security;
revoke all on public.gh_settings from anon, authenticated;
alter table public.gh_voted enable row level security;
alter table public.gh_tally enable row level security;
revoke all on public.gh_rounds, public.gh_voted, public.gh_tally from anon, authenticated;

-- ---------- Ayudantes ----------
create or replace function public.gh_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admin_users a where a.user_id = auth.uid());
$$;

create or replace function public.gh_tz()
returns text
language sql
immutable
as $$ select 'America/Argentina/Buenos_Aires'::text $$;

-- Fecha y hora actual en Argentina.
create or replace function public.gh_local_now()
returns timestamp
language sql
stable
as $$ select now() at time zone public.gh_tz() $$;

-- Crea una votación con su conteo en cero para cada candidato.
drop function if exists public.gh_new_round(text, date, uuid, timestamptz, timestamptz, uuid[]);
create or replace function public.gh_new_round(
  p_kind text, p_week date, p_parent uuid, p_opens timestamptz, p_closes timestamptz, p_candidates uuid[], p_voters uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.gh_rounds (kind, week_date, parent_id, opens_at, closes_at, candidates, voters, eligible, admin_sees)
  values (p_kind, p_week, p_parent, p_opens, p_closes, p_candidates, p_voters,
          coalesce(array_length(p_voters, 1), (select count(*) from auth.users)::int), true)
  returning id into v_id;

  insert into public.gh_tally (round_id, target)
  select v_id, x from unnest(p_candidates) as x;

  return v_id;
end;
$$;

-- Nominados (participantes) y votantes según la casa (solo usuarios que existen).
-- Si todavía no se cargó la casa, se puede votar a todos.
create or replace function public.gh_cfg_nominees()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select case when (select statuses from public.gh_settings where id = 1) = '{}'::jsonb
    then (select array_agg(id) from auth.users)
    else (select array_agg(u.id) from auth.users u, public.gh_settings s
          where s.id = 1 and s.statuses ->> u.id::text = 'participante')
  end;
$$;

-- Votan todos los registrados, o solo los que juegan (participantes, inmunes y eliminados).
create or replace function public.gh_cfg_voters()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select case when (select only_nominees_vote from public.gh_settings where id = 1)
                   and (select statuses from public.gh_settings where id = 1) <> '{}'::jsonb
              then (select array_agg(u.id) from auth.users u, public.gh_settings s
                    where s.id = 1 and s.statuses ? u.id::text)
         end;
$$;

-- Abre la votación de la semana y los desempates que hagan falta.
-- Se ejecuta cada vez que alguien entra a la sección.
create or replace function public.gh_sync()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local timestamp := public.gh_local_now();
  v_today date := v_local::date;
  v_friday date;
  r public.gh_rounds;
  v_max int;
  v_tied uuid[];
  v_end timestamptz;
begin
  perform pg_advisory_xact_lock(hashtext('gh_sync'));

  -- Jueves 22:00 hasta viernes 23:59: votación de la semana (si todavía no hay una).
  if (extract(isodow from v_local) = 4 and v_local::time >= time '22:00') or extract(isodow from v_local) = 5 then
    v_friday := case when extract(isodow from v_local) = 4 then v_today + 1 else v_today end;
    if not exists (select 1 from public.gh_rounds where kind = 'semanal' and week_date = v_friday) then
      perform public.gh_new_round(
        'semanal', v_friday, null,
        ((v_friday - 1) + time '22:00') at time zone public.gh_tz(),
        (v_friday + time '23:59') at time zone public.gh_tz(),
        public.gh_cfg_nominees(), public.gh_cfg_voters()
      );
    end if;
  end if;

  -- Votaciones cerradas que todavía no se revisaron: si hay empate, desempate.
  for r in
    select * from public.gh_rounds
    where not tie_handled and (closed_at is not null or closes_at <= now())
    order by created_at
  loop
    select max(votes) into v_max from public.gh_tally where round_id = r.id;
    select array_agg(target) into v_tied from public.gh_tally where round_id = r.id and votes = v_max;

    if coalesce(v_max, 0) > 0 and array_length(v_tied, 1) > 1 then
      v_end := coalesce(r.closed_at, r.closes_at) + interval '24 hours';
      if v_end < now() + interval '1 hour' then
        v_end := now() + interval '24 hours';
      end if;
      perform public.gh_new_round('desempate', r.week_date, r.id, now(), v_end, v_tied, r.voters);
    elsif coalesce(v_max, 0) > 0 then
      -- Ganó uno solo: pasa a eliminado (si era participante).
      update public.gh_settings
         set statuses = jsonb_set(statuses, array[v_tied[1]::text], '"eliminado"')
       where id = 1 and statuses ->> v_tied[1]::text = 'participante';
    end if;

    update public.gh_rounds set tie_handled = true where id = r.id;
  end loop;
end;
$$;

revoke all on function public.gh_is_admin() from public, anon, authenticated;
revoke all on function public.gh_new_round(text, date, uuid, timestamptz, timestamptz, uuid[], uuid[]) from public, anon, authenticated;
revoke all on function public.gh_cfg_nominees() from public, anon, authenticated;
revoke all on function public.gh_cfg_voters() from public, anon, authenticated;
revoke all on function public.gh_sync() from public, anon, authenticated;

-- ---------- Leer todo ----------
create or replace function public.gh_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  perform public.gh_sync();

  return jsonb_build_object(
    'settings', jsonb_build_object(
      'statuses', (select statuses from public.gh_settings where id = 1),
      'only_nominees_vote', (select only_nominees_vote from public.gh_settings where id = 1)
    ),
    'past', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'week', p.week, 'name', p.name) order by p.week desc), '[]'::jsonb)
             from public.gh_past p),
    -- La casa: visible para todos.
    'house', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', u.id,
        'name', coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1), 'Integrante'),
        'avatar_url', u.raw_user_meta_data ->> 'avatar_url',
        'status', s.statuses ->> u.id::text
      ) order by coalesce(u.raw_user_meta_data ->> 'full_name', u.email)), '[]'::jsonb)
      from auth.users u, public.gh_settings s
      where s.id = 1 and s.statuses ? u.id::text
    ),
    'rounds', coalesce((
    select jsonb_agg(x.j order by x.created_at desc)
    from (
      select r.created_at, jsonb_build_object(
        'id', r.id,
        'kind', r.kind,
        'week_date', r.week_date,
        'opens_at', r.opens_at,
        'closes_at', coalesce(r.closed_at, r.closes_at),
        'closed', (r.closed_at is not null or r.closes_at <= now()),
        'eligible', r.eligible,
        'voters_count', (select count(*) from public.gh_voted v where v.round_id = r.id),
        'i_voted', exists (select 1 from public.gh_voted v where v.round_id = r.id and v.user_id = v_me),
        'can_vote', (r.voters is null or v_me = any (r.voters)),
        'admin_sees', r.admin_sees,
        'candidates', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'id', u.id,
            'name', coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1), 'Integrante'),
            'avatar_url', u.raw_user_meta_data ->> 'avatar_url'
          ) order by coalesce(u.raw_user_meta_data ->> 'full_name', u.email)), '[]'::jsonb)
          from auth.users u where u.id = any (r.candidates)
        ),
        -- Los votos solo salen cuando la votación ya cerró.
        'results', case when r.closed_at is not null or r.closes_at <= now() then (
          select coalesce(jsonb_agg(jsonb_build_object('id', t.target, 'votes', t.votes)), '[]'::jsonb)
          from public.gh_tally t where t.round_id = r.id
        ) end
      ) as j
      from public.gh_rounds r
      order by r.created_at desc
      limit 40
    ) x
  ), '[]'::jsonb));
end;
$$;

-- ---------- Votar ----------
create or replace function public.gh_vote(p_round_id uuid, p_target uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.gh_rounds;
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  select * into r from public.gh_rounds where id = p_round_id for update;
  if not found then
    raise exception 'No se encontró la votación.';
  end if;
  if r.closed_at is not null or now() >= r.closes_at or now() < r.opens_at then
    raise exception 'Esta votación no está abierta.';
  end if;
  if not (p_target = any (r.candidates)) then
    raise exception 'Esa persona no está en esta votación.';
  end if;
  if r.voters is not null and not (auth.uid() = any (r.voters)) then
    raise exception 'En esta votación votan solo los que juegan.';
  end if;

  begin
    insert into public.gh_voted (round_id, user_id) values (p_round_id, auth.uid());
  exception when unique_violation then
    raise exception 'Ya votaste en esta votación. El voto no se puede cambiar.';
  end;

  -- Se reescriben todas las filas para que no quede rastro de a quién fue el voto.
  update public.gh_tally
     set votes = votes + (target = p_target)::int
   where round_id = p_round_id;

  update public.gh_voted
     set touch = touch + 1
   where round_id = p_round_id;

  -- Solo en las votaciones donde se avisó que el admin lo puede ver.
  if r.admin_sees then
    insert into public.gh_admin_log (round_id, voter, target) values (p_round_id, auth.uid(), p_target);
  end if;
end;
$$;

-- Historial de quién votó a quién: solo admin, solo votaciones cerradas con admin_sees.
create or replace function public.gh_admin_votes()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.gh_is_admin() then
    raise exception 'Solo el admin puede ver el historial de votos.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'round_id', r.id,
      'votes', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'voter', coalesce(v.raw_user_meta_data ->> 'full_name', v.raw_user_meta_data ->> 'name', split_part(v.email, '@', 1)),
          'target', coalesce(t.raw_user_meta_data ->> 'full_name', t.raw_user_meta_data ->> 'name', split_part(t.email, '@', 1))
        ) order by coalesce(v.raw_user_meta_data ->> 'full_name', v.email)), '[]'::jsonb)
        from public.gh_admin_log l
        join auth.users v on v.id = l.voter
        join auth.users t on t.id = l.target
        where l.round_id = r.id
      )
    ) order by r.created_at desc)
    from public.gh_rounds r
    where r.admin_sees and (r.closed_at is not null or r.closes_at <= now())
  ), '[]'::jsonb);
end;
$$;

-- ---------- Solo admin ----------
create or replace function public.gh_open_now()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local timestamp := public.gh_local_now();
  v_friday date;
begin
  if not public.gh_is_admin() then
    raise exception 'Solo el admin puede abrir una votación.';
  end if;
  if exists (select 1 from public.gh_rounds
             where kind = 'semanal' and closed_at is null and now() < closes_at) then
    raise exception 'Ya hay una votación abierta.';
  end if;

  -- Cierra el viernes que viene a las 23:59 (o hoy, si es viernes).
  v_friday := v_local::date + ((5 - extract(isodow from v_local)::int + 7) % 7);

  return public.gh_new_round(
    'semanal', v_friday, null, now(),
    (v_friday + time '23:59') at time zone public.gh_tz(),
    public.gh_cfg_nominees(), public.gh_cfg_voters()
  );
end;
$$;

create or replace function public.gh_close_now(p_round_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gh_is_admin() then
    raise exception 'Solo el admin puede cerrar una votación.';
  end if;

  update public.gh_rounds set closed_at = now()
  where id = p_round_id and closed_at is null and now() < closes_at;
  if not found then
    raise exception 'Esa votación ya está cerrada.';
  end if;

  perform public.gh_sync();
end;
$$;

-- Guarda los nominados (y quiénes votan) para las próximas votaciones.
create or replace function public.gh_set_nominees(p_nominees uuid[], p_only_nominees_vote boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gh_is_admin() then
    raise exception 'Solo el admin puede elegir a los nominados.';
  end if;
  if coalesce(array_length(p_nominees, 1), 0) < 2 then
    raise exception 'Elegí al menos 2 nominados.';
  end if;
  update public.gh_settings
     set nominees = p_nominees, only_nominees_vote = coalesce(p_only_nominees_vote, false)
   where id = 1;
end;
$$;

-- Guarda el estado de cada integrante en la casa.
create or replace function public.gh_set_statuses(p_statuses jsonb, p_only_players_vote boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clean jsonb;
begin
  if not public.gh_is_admin() then
    raise exception 'Solo el admin puede cambiar la casa.';
  end if;

  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) into v_clean
  from jsonb_each(coalesce(p_statuses, '{}'::jsonb)) e
  where e.value #>> '{}' in ('participante', 'inmune', 'eliminado')
    and exists (select 1 from auth.users u where u.id::text = e.key);

  if (select count(*) from jsonb_each(v_clean) e where e.value #>> '{}' = 'participante') < 2 then
    raise exception 'Tiene que haber al menos 2 participantes.';
  end if;

  update public.gh_settings
     set statuses = v_clean, only_nominees_vote = coalesce(p_only_players_vote, false)
   where id = 1;
end;
$$;

-- Historial de antes de la página: agregar/corregir y borrar (solo admin).
create or replace function public.gh_past_save(p_week int, p_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gh_is_admin() then
    raise exception 'Solo el admin puede editar el historial.';
  end if;
  insert into public.gh_past (week, name) values (p_week, left(btrim(p_name), 40))
  on conflict (week) do update set name = excluded.name;
end;
$$;

create or replace function public.gh_past_delete(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.gh_is_admin() then
    raise exception 'Solo el admin puede editar el historial.';
  end if;
  delete from public.gh_past where id = p_id;
end;
$$;

-- Aplica la lista de nominados a una votación abierta en la que todavía nadie votó.
create or replace function public.gh_apply_nominees(p_round_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.gh_rounds;
begin
  if not public.gh_is_admin() then
    raise exception 'Solo el admin puede cambiar los nominados.';
  end if;
  select * into r from public.gh_rounds where id = p_round_id for update;
  if not found or r.kind <> 'semanal' or r.closed_at is not null or now() >= r.closes_at then
    raise exception 'Solo se puede en una votación semanal abierta.';
  end if;
  if exists (select 1 from public.gh_voted where round_id = p_round_id) then
    raise exception 'Ya votó alguien: los nominados de esta votación no se pueden cambiar.';
  end if;

  update public.gh_rounds
     set candidates = public.gh_cfg_nominees(),
         voters = public.gh_cfg_voters(),
         eligible = coalesce(array_length(public.gh_cfg_voters(), 1), (select count(*) from auth.users)::int)
   where id = p_round_id;
  delete from public.gh_tally where round_id = p_round_id;
  insert into public.gh_tally (round_id, target)
  select p_round_id, x from unnest(public.gh_cfg_nominees()) as x;
end;
$$;

-- ---------- Permisos ----------
revoke all on function public.gh_state() from public, anon;
revoke all on function public.gh_vote(uuid, uuid) from public, anon;
revoke all on function public.gh_open_now() from public, anon;
revoke all on function public.gh_close_now(uuid) from public, anon;
revoke all on function public.gh_set_nominees(uuid[], boolean) from public, anon;
revoke all on function public.gh_apply_nominees(uuid) from public, anon;
revoke all on function public.gh_set_statuses(jsonb, boolean) from public, anon;
revoke all on function public.gh_past_save(int, text) from public, anon;
revoke all on function public.gh_past_delete(uuid) from public, anon;
revoke all on function public.gh_admin_votes() from public, anon;

grant execute on function public.gh_state() to authenticated;
grant execute on function public.gh_vote(uuid, uuid) to authenticated;
grant execute on function public.gh_open_now() to authenticated;
grant execute on function public.gh_close_now(uuid) to authenticated;
grant execute on function public.gh_set_nominees(uuid[], boolean) to authenticated;
grant execute on function public.gh_apply_nominees(uuid) to authenticated;
grant execute on function public.gh_set_statuses(jsonb, boolean) to authenticated;
grant execute on function public.gh_past_save(int, text) to authenticated;
grant execute on function public.gh_past_delete(uuid) to authenticated;
grant execute on function public.gh_admin_votes() to authenticated;
