-- Amigo invisible: sorteos, listas de deseos y asignaciones secretas.
-- Pegar y ejecutar UNA vez en Supabase → SQL Editor (se puede repetir sin problema).
--
-- Las asignaciones (quién le regala a quién) no se pueden leer directamente:
-- cada integrante solo ve la suya a través de ss_state(), y todas se ven
-- únicamente después de que el admin las revela.

-- ---------- Tablas ----------
create table if not exists public.secret_santa (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 80),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  drawn_at timestamptz,
  revealed boolean not null default false
);

create table if not exists public.secret_santa_participants (
  santa_id uuid not null references public.secret_santa (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  wishlist text check (char_length(wishlist) <= 500),
  primary key (santa_id, user_id)
);

create table if not exists public.secret_santa_assignments (
  santa_id uuid not null references public.secret_santa (id) on delete cascade,
  giver_id uuid not null references auth.users (id) on delete cascade,
  receiver_id uuid not null references auth.users (id) on delete cascade,
  primary key (santa_id, giver_id)
);

-- RLS activado y SIN reglas de lectura: nadie lee estas tablas directo,
-- todo pasa por las funciones de abajo.
alter table public.secret_santa enable row level security;
alter table public.secret_santa_participants enable row level security;
alter table public.secret_santa_assignments enable row level security;
revoke all on public.secret_santa, public.secret_santa_participants, public.secret_santa_assignments from anon, authenticated;

-- ---------- Ayudantes ----------
create or replace function public.ss_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admin_users a where a.user_id = auth.uid());
$$;

create or replace function public.ss_member(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', u.id,
    'name', coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', split_part(u.email, '@', 1), 'Integrante'),
    'avatar_url', u.raw_user_meta_data ->> 'avatar_url'
  )
  from auth.users u
  where u.id = p_user;
$$;

revoke all on function public.ss_is_admin() from public, anon, authenticated;
revoke all on function public.ss_member(uuid) from public, anon, authenticated;

-- ---------- Lo que ve cada integrante ----------
create or replace function public.ss_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'title', s.title,
        'created_at', s.created_at,
        'drawn_at', s.drawn_at,
        'revealed', s.revealed,
        'participants', (
          select coalesce(jsonb_agg(public.ss_member(p.user_id) || jsonb_build_object('has_wishlist', coalesce(p.wishlist, '') <> '') order by p.user_id), '[]'::jsonb)
          from public.secret_santa_participants p
          where p.santa_id = s.id
        ),
        'me', (
          select jsonb_build_object('wishlist', p.wishlist)
          from public.secret_santa_participants p
          where p.santa_id = s.id and p.user_id = v_me
        ),
        -- Solo mi asignación: a quién le regalo yo y su lista de deseos.
        'my_match', (
          select public.ss_member(a.receiver_id) || jsonb_build_object('wishlist', rp.wishlist)
          from public.secret_santa_assignments a
          left join public.secret_santa_participants rp
            on rp.santa_id = a.santa_id and rp.user_id = a.receiver_id
          where a.santa_id = s.id and a.giver_id = v_me
        ),
        -- Todas las asignaciones, solo después de revelarlas.
        'reveal', case when s.revealed then (
          select coalesce(jsonb_agg(jsonb_build_object('giver', public.ss_member(a.giver_id), 'receiver', public.ss_member(a.receiver_id))), '[]'::jsonb)
          from public.secret_santa_assignments a
          where a.santa_id = s.id
        ) end
      )
      order by s.created_at desc
    )
    from public.secret_santa s
  ), '[]'::jsonb);
end;
$$;

-- ---------- Lista de deseos (cada uno la suya) ----------
create or replace function public.ss_set_wishlist(p_santa_id uuid, p_wishlist text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;
  if exists (select 1 from public.secret_santa where id = p_santa_id and revealed) then
    raise exception 'Este sorteo ya fue revelado.';
  end if;

  update public.secret_santa_participants
     set wishlist = nullif(left(btrim(coalesce(p_wishlist, '')), 500), '')
   where santa_id = p_santa_id and user_id = auth.uid();

  if not found then
    raise exception 'No participás en este sorteo.';
  end if;
end;
$$;

-- ---------- Solo admin: crear, sortear, revelar, eliminar ----------
create or replace function public.ss_create(p_title text, p_user_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_users uuid[];
begin
  if not public.ss_is_admin() then
    raise exception 'Solo el administrador puede crear sorteos.';
  end if;

  select array_agg(distinct x) into v_users
  from unnest(p_user_ids) as x
  where exists (select 1 from auth.users u where u.id = x);

  if coalesce(array_length(v_users, 1), 0) < 3 then
    raise exception 'El amigo invisible necesita al menos 3 participantes.';
  end if;

  insert into public.secret_santa (title, created_by)
  values (left(btrim(p_title), 80), auth.uid())
  returning id into v_id;

  insert into public.secret_santa_participants (santa_id, user_id)
  select v_id, x from unnest(v_users) as x;

  return v_id;
end;
$$;

-- Sortea (o vuelve a sortear). Ordena a los participantes al azar y arma
-- una sola cadena: cada uno le regala al siguiente y el último al primero.
-- Así nadie se toca a sí mismo, nadie se repite y no quedan parejas cerradas.
create or replace function public.ss_draw(p_santa_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order uuid[];
  n int;
begin
  if not public.ss_is_admin() then
    raise exception 'Solo el administrador puede sortear.';
  end if;
  if exists (select 1 from public.secret_santa where id = p_santa_id and revealed) then
    raise exception 'Este sorteo ya fue revelado y no se puede volver a sortear.';
  end if;

  select array_agg(user_id order by random()) into v_order
  from public.secret_santa_participants
  where santa_id = p_santa_id;

  n := coalesce(array_length(v_order, 1), 0);
  if n < 3 then
    raise exception 'El amigo invisible necesita al menos 3 participantes.';
  end if;

  delete from public.secret_santa_assignments where santa_id = p_santa_id;

  insert into public.secret_santa_assignments (santa_id, giver_id, receiver_id)
  select p_santa_id, v_order[i], v_order[(i % n) + 1]
  from generate_series(1, n) as i;

  update public.secret_santa set drawn_at = now() where id = p_santa_id;
end;
$$;

create or replace function public.ss_reveal(p_santa_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.ss_is_admin() then
    raise exception 'Solo el administrador puede revelar las asignaciones.';
  end if;

  update public.secret_santa
     set revealed = true
   where id = p_santa_id and drawn_at is not null;

  if not found then
    raise exception 'Primero hay que hacer el sorteo.';
  end if;
end;
$$;

create or replace function public.ss_delete(p_santa_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.ss_is_admin() then
    raise exception 'Solo el administrador puede eliminar sorteos.';
  end if;
  delete from public.secret_santa where id = p_santa_id;
end;
$$;

-- ---------- Permisos ----------
revoke all on function public.ss_state() from public, anon;
revoke all on function public.ss_set_wishlist(uuid, text) from public, anon;
revoke all on function public.ss_create(text, uuid[]) from public, anon;
revoke all on function public.ss_draw(uuid) from public, anon;
revoke all on function public.ss_reveal(uuid) from public, anon;
revoke all on function public.ss_delete(uuid) from public, anon;

grant execute on function public.ss_state() to authenticated;
grant execute on function public.ss_set_wishlist(uuid, text) to authenticated;
grant execute on function public.ss_create(text, uuid[]) to authenticated;
grant execute on function public.ss_draw(uuid) to authenticated;
grant execute on function public.ss_reveal(uuid) to authenticated;
grant execute on function public.ss_delete(uuid) to authenticated;
