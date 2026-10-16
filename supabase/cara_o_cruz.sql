-- Cara o cruz: versus entre integrantes, con historial.
-- Pegar y ejecutar UNA vez en Supabase → SQL Editor (se puede repetir sin problema).
-- Desde el celular, usar cara_o_cruz_celular_1.sql (y las partes que haya).
--
-- La moneda la tira la base de datos, así nadie puede elegir el resultado.
-- El rival juega siempre con el lado contrario al que elige quien desafía.

create table if not exists public.coin_duels (
  id uuid primary key default gen_random_uuid(),
  p1 uuid not null references auth.users (id) on delete cascade,
  p2 uuid not null references auth.users (id) on delete cascade,
  p1_side text not null check (p1_side in ('cara', 'cruz')),
  result text not null check (result in ('cara', 'cruz')),
  stake text check (char_length(stake) <= 60),
  created_at timestamptz not null default now(),
  check (p1 <> p2)
);

alter table public.coin_duels enable row level security;
revoke all on public.coin_duels from anon, authenticated;

create or replace function public.cf_name(p_user uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1), 'Integrante')
  from auth.users u where u.id = p_user;
$$;
revoke all on function public.cf_name(uuid) from public, anon, authenticated;

-- Historial (los últimos 500 versus).
create or replace function public.cf_state()
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

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', d.id,
      'p1', d.p1, 'p1_name', public.cf_name(d.p1), 'p1_side', d.p1_side,
      'p2', d.p2, 'p2_name', public.cf_name(d.p2),
      'result', d.result, 'stake', d.stake, 'created_at', d.created_at
    ) order by d.created_at desc)
    from (select * from public.coin_duels order by created_at desc limit 500) d
  ), '[]'::jsonb);
end;
$$;

-- Tirar la moneda contra un rival. Devuelve el versus guardado.
create or replace function public.cf_duel(p_rival uuid, p_side text, p_stake text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_result text := case when random() < 0.5 then 'cara' else 'cruz' end;
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;
  if p_side not in ('cara', 'cruz') then
    raise exception 'Elegí cara o cruz.';
  end if;
  if p_rival is null or p_rival = auth.uid() then
    raise exception 'Elegí un rival que no seas vos.';
  end if;
  if not exists (select 1 from auth.users where id = p_rival) then
    raise exception 'No se encontró al rival.';
  end if;

  insert into public.coin_duels (p1, p2, p1_side, result, stake)
  values (auth.uid(), p_rival, p_side, v_result, nullif(left(btrim(coalesce(p_stake, '')), 60), ''))
  returning id into v_id;

  return (
    select jsonb_build_object(
      'id', d.id,
      'p1', d.p1, 'p1_name', public.cf_name(d.p1), 'p1_side', d.p1_side,
      'p2', d.p2, 'p2_name', public.cf_name(d.p2),
      'result', d.result, 'stake', d.stake, 'created_at', d.created_at
    )
    from public.coin_duels d where d.id = v_id
  );
end;
$$;

-- Borrar un versus (solo admin).
create or replace function public.cf_delete(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.admin_users a where a.user_id = auth.uid()) then
    raise exception 'Solo el admin puede borrar versus.';
  end if;
  delete from public.coin_duels where id = p_id;
end;
$$;

revoke all on function public.cf_state() from public, anon;
revoke all on function public.cf_duel(uuid, text, text) from public, anon;
revoke all on function public.cf_delete(uuid) from public, anon;
grant execute on function public.cf_state() to authenticated;
grant execute on function public.cf_duel(uuid, text, text) to authenticated;
grant execute on function public.cf_delete(uuid) to authenticated;
