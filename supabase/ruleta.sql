-- Ruleta: lista de integrantes, giros y su historial.
-- Pegar y ejecutar UNA vez en Supabase → SQL Editor.

-- 1) Integrantes registrados (nombre y foto de su cuenta de Google).
create or replace function public.get_members()
returns table (id uuid, full_name text, avatar_url text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  return query
  select
    u.id,
    coalesce(
      u.raw_user_meta_data ->> 'full_name',
      u.raw_user_meta_data ->> 'name',
      split_part(u.email, '@', 1),
      'Integrante'
    )::text,
    (u.raw_user_meta_data ->> 'avatar_url')::text
  from auth.users u
  order by 2;
end;
$$;

revoke all on function public.get_members() from public, anon;
grant execute on function public.get_members() to authenticated;

-- 2) Historial de giros.
create table if not exists public.wheel_spins (
  id uuid primary key default gen_random_uuid(),
  spun_by uuid references auth.users (id) on delete set null,
  spinner_name text,
  winner text not null,
  entries text[] not null,
  created_at timestamptz not null default now()
);

alter table public.wheel_spins enable row level security;

-- Toda la banda puede ver el historial.
drop policy if exists "Ver historial de la ruleta" on public.wheel_spins;
create policy "Ver historial de la ruleta" on public.wheel_spins
  for select to authenticated
  using (true);

-- Solo el admin puede borrar giros del historial.
drop policy if exists "Admin borra giros" on public.wheel_spins;
create policy "Admin borra giros" on public.wheel_spins
  for delete to authenticated
  using (exists (select 1 from public.admin_users a where a.user_id = auth.uid()));

-- No hay regla para insertar: los giros solo se guardan con spin_wheel,
-- así nadie puede anotar un ganador a mano.

-- 3) Girar: el ganador lo elige la base de datos al azar y queda guardado.
create or replace function public.spin_wheel(p_entries text[])
returns setof public.wheel_spins
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_entries text[];
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  select array_agg(e) into v_entries
  from (select left(btrim(x), 60) as e from unnest(p_entries) as x) t
  where e <> '';

  if coalesce(array_length(v_entries, 1), 0) < 2 then
    raise exception 'La ruleta necesita al menos 2 opciones.';
  end if;
  if array_length(v_entries, 1) > 100 then
    raise exception 'La ruleta admite como máximo 100 opciones.';
  end if;

  select coalesce(
           u.raw_user_meta_data ->> 'full_name',
           u.raw_user_meta_data ->> 'name',
           split_part(u.email, '@', 1)
         )
    into v_name
  from auth.users u
  where u.id = auth.uid();

  return query
  insert into public.wheel_spins (spun_by, spinner_name, winner, entries)
  values (
    auth.uid(),
    v_name,
    v_entries[1 + floor(random() * array_length(v_entries, 1))::int],
    v_entries
  )
  returning *;
end;
$$;

revoke all on function public.spin_wheel(text[]) from public, anon;
grant execute on function public.spin_wheel(text[]) to authenticated;
