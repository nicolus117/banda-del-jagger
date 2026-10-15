-- Cierre de votaciones: fecha límite opcional para cada votación.
-- Pegar y ejecutar UNA vez en Supabase → SQL Editor (se puede repetir sin problema).

-- 1) Nueva columna con la fecha y hora de cierre (vacía = no cierra nunca).
alter table public.polls add column if not exists closes_at timestamptz;

-- 2) Guardar o cambiar la fecha de cierre: solo quien creó la votación o el admin.
create or replace function public.set_poll_deadline(p_poll_id uuid, p_closes_at timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  if not exists (
    select 1 from public.polls p
    where p.id = p_poll_id
      and (p.created_by = auth.uid()
           or exists (select 1 from public.admin_users a where a.user_id = auth.uid()))
  ) then
    raise exception 'Solo quien creó la votación o el admin pueden cambiar su cierre.';
  end if;

  update public.polls set closes_at = p_closes_at where id = p_poll_id;
end;
$$;

revoke all on function public.set_poll_deadline(uuid, timestamptz) from public, anon;
grant execute on function public.set_poll_deadline(uuid, timestamptz) to authenticated;

-- 3) La base de datos rechaza votos en votaciones cerradas, aunque alguien
--    intente saltearse la página.
create or replace function public.votes_reject_closed_poll()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.polls p
    where p.id = new.poll_id and p.closes_at is not null and p.closes_at <= now()
  ) then
    raise exception 'Esta votación ya cerró.';
  end if;
  return new;
end;
$$;

drop trigger if exists votes_reject_closed_poll on public.votes;
create trigger votes_reject_closed_poll
  before insert or update on public.votes
  for each row execute function public.votes_reject_closed_poll();
