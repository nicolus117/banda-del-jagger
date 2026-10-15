-- Truco: historial de partidas y torneos (llaves o todos contra todos).
-- Pegar y ejecutar UNA vez en Supabase → SQL Editor (se puede repetir sin problema).
--
-- Reglas:
--   * Cualquier integrante guarda partidas y crea torneos.
--   * Un resultado de torneo lo cargan quien creó el torneo, los jugadores
--     de ese partido o el admin.
--   * Partidas y torneos los borra quien los creó o el admin.
-- Todo pasa por las funciones de abajo; las tablas no se tocan directo.

-- ---------- Tablas ----------
create table if not exists public.truco_tournaments (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 80),
  mode int not null check (mode in (1, 2, 3)),
  format text not null check (format in ('llaves', 'liga')),
  target int not null check (target in (15, 30)),
  champion int,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

-- players: [{"id": uuid o null, "name": "Nico"}]
create table if not exists public.truco_teams (
  tournament_id uuid not null references public.truco_tournaments (id) on delete cascade,
  idx int not null,
  name text not null,
  players jsonb not null,
  primary key (tournament_id, idx)
);

create table if not exists public.truco_tmatches (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.truco_tournaments (id) on delete cascade,
  round int not null,
  slot int not null,
  team_a int,
  team_b int,
  bye boolean not null default false,
  winner int,
  pts_a int,
  pts_b int,
  unique (tournament_id, round, slot)
);

create table if not exists public.truco_matches (
  id uuid primary key default gen_random_uuid(),
  team_a text not null,
  team_b text not null,
  score_a int not null check (score_a between 0 and 30),
  score_b int not null check (score_b between 0 and 30),
  target int not null check (target in (15, 30)),
  tournament_id uuid references public.truco_tournaments (id) on delete cascade,
  tmatch_id uuid references public.truco_tmatches (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.truco_tournaments enable row level security;
alter table public.truco_teams enable row level security;
alter table public.truco_tmatches enable row level security;
alter table public.truco_matches enable row level security;
revoke all on public.truco_tournaments, public.truco_teams, public.truco_tmatches, public.truco_matches from anon, authenticated;

-- ---------- Ayudantes ----------
create or replace function public.tr_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admin_users a where a.user_id = auth.uid());
$$;

-- ¿El usuario actual juega en el equipo idx de ese torneo?
create or replace function public.tr_plays_in(p_tournament uuid, p_idx int)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.truco_teams t, jsonb_array_elements(t.players) p
    where t.tournament_id = p_tournament and t.idx = p_idx
      and p ->> 'id' = auth.uid()::text
  );
$$;

-- Si ya se jugaron todos los partidos de una liga, define el campeón:
-- más partidos ganados y, si empatan, mayor diferencia de puntos.
create or replace function public.tr_check_league(p_tournament uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.truco_tmatches where tournament_id = p_tournament and winner is null) then
    update public.truco_tournaments set champion = null where id = p_tournament;
    return;
  end if;

  update public.truco_tournaments set champion = (
    select t.idx
    from public.truco_teams t
    left join public.truco_tmatches m
      on m.tournament_id = t.tournament_id and (m.team_a = t.idx or m.team_b = t.idx)
    where t.tournament_id = p_tournament
    group by t.idx
    order by count(*) filter (where m.winner = t.idx) desc,
             sum(case when m.team_a = t.idx then coalesce(m.pts_a, 0) - coalesce(m.pts_b, 0)
                      else coalesce(m.pts_b, 0) - coalesce(m.pts_a, 0) end) desc,
             t.idx
    limit 1
  )
  where id = p_tournament;
end;
$$;

-- En llaves, pone al ganador de un partido en el lugar que le toca en la ronda siguiente.
create or replace function public.tr_advance(p_tournament uuid, p_round int, p_slot int, p_team int)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.truco_tmatches where tournament_id = p_tournament and round = p_round + 1) then
    update public.truco_tournaments set champion = p_team where id = p_tournament;
    return;
  end if;

  if p_slot % 2 = 0 then
    update public.truco_tmatches set team_a = p_team
    where tournament_id = p_tournament and round = p_round + 1 and slot = p_slot / 2;
  else
    update public.truco_tmatches set team_b = p_team
    where tournament_id = p_tournament and round = p_round + 1 and slot = p_slot / 2;
  end if;
end;
$$;

revoke all on function public.tr_is_admin() from public, anon, authenticated;
revoke all on function public.tr_plays_in(uuid, int) from public, anon, authenticated;
revoke all on function public.tr_check_league(uuid) from public, anon, authenticated;
revoke all on function public.tr_advance(uuid, int, int, int) from public, anon, authenticated;

-- ---------- Leer todo ----------
create or replace function public.tr_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  return jsonb_build_object(
    'tournaments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id, 'title', t.title, 'mode', t.mode, 'format', t.format, 'target', t.target,
        'champion', t.champion, 'created_by', t.created_by, 'created_at', t.created_at,
        'teams', (select coalesce(jsonb_agg(jsonb_build_object('idx', x.idx, 'name', x.name, 'players', x.players) order by x.idx), '[]'::jsonb)
                  from public.truco_teams x where x.tournament_id = t.id),
        'matches', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', m.id, 'round', m.round, 'slot', m.slot, 'a', m.team_a, 'b', m.team_b,
                      'bye', m.bye, 'winner', m.winner, 'pts_a', m.pts_a, 'pts_b', m.pts_b) order by m.round, m.slot), '[]'::jsonb)
                    from public.truco_tmatches m where m.tournament_id = t.id)
      ) order by t.created_at desc)
      from public.truco_tournaments t
    ), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(h order by h.created_at desc) from (
        select m.id, m.team_a, m.team_b, m.score_a, m.score_b, m.target, m.created_by, m.created_at,
               t.title as tournament
        from public.truco_matches m
        left join public.truco_tournaments t on t.id = m.tournament_id
        order by m.created_at desc
        limit 50
      ) h
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------- Partidas sueltas ----------
create or replace function public.tr_save_match(p_team_a text, p_team_b text, p_score_a int, p_score_b int, p_target int)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;
  if greatest(p_score_a, p_score_b) <> p_target or least(p_score_a, p_score_b) >= p_target then
    raise exception 'La partida tiene que estar terminada para guardarla.';
  end if;

  insert into public.truco_matches (team_a, team_b, score_a, score_b, target, created_by)
  values (left(coalesce(nullif(btrim(p_team_a), ''), 'Nos'), 40), left(coalesce(nullif(btrim(p_team_b), ''), 'Ellos'), 40),
          p_score_a, p_score_b, p_target, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.tr_delete_match(p_match_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.truco_matches
  where id = p_match_id and tournament_id is null and (created_by = auth.uid() or public.tr_is_admin());
  if not found then
    raise exception 'Solo quien guardó la partida o el admin pueden borrarla. Las de torneo se borran con el torneo.';
  end if;
end;
$$;

-- ---------- Torneos ----------
-- p_teams: [{"name": "Nico y Tobi", "players": [{"id": "...", "name": "Nico"}, {"id": null, "name": "Tobi"}]}, ...]
-- El orden de los equipos es el de las llaves (la página ya los mezcla si es sorteo).
create or replace function public.tr_create_tournament(p_title text, p_mode int, p_format text, p_target int, p_teams jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  n int := jsonb_array_length(p_teams);
  v_size int := 1;
  v_rounds int := 0;
  r int;
  s int;
  i int;
  j int;
  k int := 0;
  hi int;
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;
  if n < 2 then
    raise exception 'Un torneo necesita al menos 2 equipos.';
  end if;
  if n > 32 then
    raise exception 'Máximo 32 equipos.';
  end if;
  if exists (select 1 from jsonb_array_elements(p_teams) e where jsonb_array_length(e -> 'players') <> p_mode) then
    raise exception 'Todos los equipos tienen que tener % jugador(es).', p_mode;
  end if;

  insert into public.truco_tournaments (title, mode, format, target, created_by)
  values (left(btrim(p_title), 80), p_mode, p_format, p_target, auth.uid())
  returning id into v_id;

  insert into public.truco_teams (tournament_id, idx, name, players)
  select v_id, (e.ord - 1)::int, left(coalesce(nullif(btrim(e.val ->> 'name'), ''), 'Equipo ' || e.ord), 60), e.val -> 'players'
  from jsonb_array_elements(p_teams) with ordinality as e(val, ord);

  if p_format = 'liga' then
    for i in 0 .. n - 2 loop
      for j in i + 1 .. n - 1 loop
        insert into public.truco_tmatches (tournament_id, round, slot, team_a, team_b)
        values (v_id, 0, k, i, j);
        k := k + 1;
      end loop;
    end loop;
    return v_id;
  end if;

  -- Llaves: se completa hasta la potencia de 2 siguiente; los que no tienen
  -- rival en la primera ronda pasan directo.
  while v_size < n loop
    v_size := v_size * 2;
    v_rounds := v_rounds + 1;
  end loop;

  for r in 0 .. v_rounds - 1 loop
    for s in 0 .. (v_size / (2 ^ (r + 1)))::int - 1 loop
      insert into public.truco_tmatches (tournament_id, round, slot) values (v_id, r, s);
    end loop;
  end loop;

  for s in 0 .. v_size / 2 - 1 loop
    hi := v_size - 1 - s;
    if hi < n then
      update public.truco_tmatches set team_a = s, team_b = hi
      where tournament_id = v_id and round = 0 and slot = s;
    else
      update public.truco_tmatches set team_a = s, bye = true, winner = s
      where tournament_id = v_id and round = 0 and slot = s;
      perform public.tr_advance(v_id, 0, s, s);
    end if;
  end loop;

  return v_id;
end;
$$;

create or replace function public.tr_set_result(p_match_id uuid, p_winner int, p_pts_a int, p_pts_b int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.truco_tmatches;
  t public.truco_tournaments;
  v_next public.truco_tmatches;
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  select * into m from public.truco_tmatches where id = p_match_id;
  if not found then
    raise exception 'No se encontró el partido.';
  end if;
  select * into t from public.truco_tournaments where id = m.tournament_id;

  if not (t.created_by = auth.uid() or public.tr_is_admin()
          or public.tr_plays_in(t.id, m.team_a) or public.tr_plays_in(t.id, m.team_b)) then
    raise exception 'El resultado lo cargan quien creó el torneo, los jugadores del partido o el admin.';
  end if;
  if m.team_a is null or m.team_b is null or m.bye then
    raise exception 'Este partido todavía no tiene a los dos equipos.';
  end if;
  if p_winner not in (m.team_a, m.team_b) then
    raise exception 'El ganador tiene que ser uno de los dos equipos.';
  end if;

  -- En llaves no se puede cambiar un resultado si el ganador ya jugó el partido siguiente.
  if t.format = 'llaves' and m.winner is not null and m.winner <> p_winner then
    select * into v_next from public.truco_tmatches
    where tournament_id = t.id and round = m.round + 1 and slot = m.slot / 2;
    if found and v_next.winner is not null then
      raise exception 'No se puede cambiar: el ganador ya jugó el partido siguiente.';
    end if;
  end if;

  update public.truco_tmatches
     set winner = p_winner, pts_a = p_pts_a, pts_b = p_pts_b
   where id = m.id;

  -- Historial: se reemplaza la partida de este cruce si ya estaba cargada.
  delete from public.truco_matches where tmatch_id = m.id;
  if p_pts_a is not null and p_pts_b is not null then
    insert into public.truco_matches (team_a, team_b, score_a, score_b, target, tournament_id, tmatch_id, created_by)
    select a.name, b.name, least(greatest(p_pts_a, 0), 30), least(greatest(p_pts_b, 0), 30), t.target, t.id, m.id, auth.uid()
    from public.truco_teams a, public.truco_teams b
    where a.tournament_id = t.id and a.idx = m.team_a and b.tournament_id = t.id and b.idx = m.team_b;
  end if;

  if t.format = 'llaves' then
    perform public.tr_advance(t.id, m.round, m.slot, p_winner);
  else
    perform public.tr_check_league(t.id);
  end if;
end;
$$;

create or replace function public.tr_delete_tournament(p_tournament_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.truco_tournaments
  where id = p_tournament_id and (created_by = auth.uid() or public.tr_is_admin());
  if not found then
    raise exception 'Solo quien creó el torneo o el admin pueden borrarlo.';
  end if;
end;
$$;

-- ---------- Permisos ----------
revoke all on function public.tr_state() from public, anon;
revoke all on function public.tr_save_match(text, text, int, int, int) from public, anon;
revoke all on function public.tr_delete_match(uuid) from public, anon;
revoke all on function public.tr_create_tournament(text, int, text, int, jsonb) from public, anon;
revoke all on function public.tr_set_result(uuid, int, int, int) from public, anon;
revoke all on function public.tr_delete_tournament(uuid) from public, anon;

grant execute on function public.tr_state() to authenticated;
grant execute on function public.tr_save_match(text, text, int, int, int) to authenticated;
grant execute on function public.tr_delete_match(uuid) to authenticated;
grant execute on function public.tr_create_tournament(text, int, text, int, jsonb) to authenticated;
grant execute on function public.tr_set_result(uuid, int, int, int) to authenticated;
grant execute on function public.tr_delete_tournament(uuid) to authenticated;
