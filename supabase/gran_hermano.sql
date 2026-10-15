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
--
-- Horarios (hora de Argentina):
--   * Se abre sola cada viernes a las 00:00 y se cierra a las 23:59.
--   * El admin puede abrir una antes o cerrar la abierta cuando quiera.
--   * Si hay empate, se abre un desempate de 24 horas entre los empatados.
--     Si vuelve a empatar, otro desempate.

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

alter table public.gh_rounds enable row level security;
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

-- Crea una votación con su conteo en cero para cada candidato.
create or replace function public.gh_new_round(
  p_kind text, p_week date, p_parent uuid, p_opens timestamptz, p_closes timestamptz, p_candidates uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.gh_rounds (kind, week_date, parent_id, opens_at, closes_at, candidates, eligible)
  values (p_kind, p_week, p_parent, p_opens, p_closes, p_candidates, (select count(*) from auth.users))
  returning id into v_id;

  insert into public.gh_tally (round_id, target)
  select v_id, x from unnest(p_candidates) as x;

  return v_id;
end;
$$;

-- Abre la votación del viernes y los desempates que hagan falta.
-- Se ejecuta cada vez que alguien entra a la sección.
create or replace function public.gh_sync()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_local timestamp := now() at time zone public.gh_tz();
  v_today date := v_local::date;
  r public.gh_rounds;
  v_max int;
  v_tied uuid[];
  v_end timestamptz;
begin
  perform pg_advisory_xact_lock(hashtext('gh_sync'));

  -- Viernes a las 00:00: votación semanal (si todavía no hay una para este viernes).
  if extract(isodow from v_local) = 5
     and not exists (select 1 from public.gh_rounds where kind = 'semanal' and week_date = v_today) then
    perform public.gh_new_round(
      'semanal', v_today, null,
      (v_today::timestamp) at time zone public.gh_tz(),
      (v_today + time '23:59') at time zone public.gh_tz(),
      (select array_agg(id) from auth.users)
    );
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
      perform public.gh_new_round('desempate', r.week_date, r.id, now(), v_end, v_tied);
    end if;

    update public.gh_rounds set tie_handled = true where id = r.id;
  end loop;
end;
$$;

revoke all on function public.gh_is_admin() from public, anon, authenticated;
revoke all on function public.gh_new_round(text, date, uuid, timestamptz, timestamptz, uuid[]) from public, anon, authenticated;
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

  return coalesce((
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
  ), '[]'::jsonb);
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
  v_local timestamp := now() at time zone public.gh_tz();
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
    (select array_agg(id) from auth.users)
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

-- ---------- Permisos ----------
revoke all on function public.gh_state() from public, anon;
revoke all on function public.gh_vote(uuid, uuid) from public, anon;
revoke all on function public.gh_open_now() from public, anon;
revoke all on function public.gh_close_now(uuid) from public, anon;

grant execute on function public.gh_state() to authenticated;
grant execute on function public.gh_vote(uuid, uuid) to authenticated;
grant execute on function public.gh_open_now() to authenticated;
grant execute on function public.gh_close_now(uuid) to authenticated;
