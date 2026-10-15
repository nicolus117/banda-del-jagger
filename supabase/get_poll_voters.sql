-- Votaciones públicas: devuelve quién votó cada opción.
-- Pegar y ejecutar UNA vez en Supabase → SQL Editor.
--
-- Para votaciones anónimas no devuelve ninguna fila, así que la identidad
-- de quienes votaron nunca sale de la base de datos (la protección no
-- depende del HTML).

create or replace function public.get_poll_voters(p_poll_id uuid)
returns table (
  voter_id uuid,
  voter_name text,
  avatar_url text,
  option_id uuid,
  ranking_position integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  -- Anónima (o inexistente): no se expone nada.
  if not exists (
    select 1 from public.polls p
    where p.id = p_poll_id and coalesce(p.anonymous, true) = false
  ) then
    return;
  end if;

  return query
  select
    v.voter_id::uuid,
    coalesce(
      u.raw_user_meta_data ->> 'full_name',
      u.raw_user_meta_data ->> 'name',
      split_part(u.email, '@', 1),
      'Integrante'
    )::text,
    (u.raw_user_meta_data ->> 'avatar_url')::text,
    v.option_id::uuid,
    v.ranking_position::integer
  from public.votes v
  join auth.users u on u.id = v.voter_id
  where v.poll_id = p_poll_id
  order by v.created_at;
end;
$$;

revoke all on function public.get_poll_voters(uuid) from public, anon;
grant execute on function public.get_poll_voters(uuid) to authenticated;
