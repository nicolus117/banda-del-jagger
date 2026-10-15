-- Gastos compartidos: cuentas, gastos y pagos entre integrantes.
-- Pegar y ejecutar UNA vez en Supabase → SQL Editor (se puede repetir sin problema).
--
-- Reglas:
--   * Cualquier integrante crea cuentas y carga gastos.
--   * Un gasto lo borra quien lo cargó o el admin.
--   * "Pagado" lo marca quien paga, quien cobra o el admin.
--   * Una cuenta la borra quien la creó o el admin.
-- Todo pasa por las funciones de abajo; las tablas no se tocan directo.

-- ---------- Tablas ----------
create table if not exists public.expense_accounts (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 80),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.expense_account_members (
  account_id uuid not null references public.expense_accounts (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  primary key (account_id, user_id)
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.expense_accounts (id) on delete cascade,
  description text not null check (char_length(description) between 1 and 80),
  amount numeric(14,2) not null check (amount > 0),
  paid_by uuid not null references auth.users (id) on delete cascade,
  split uuid[] not null check (cardinality(split) > 0),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.expense_payments (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.expense_accounts (id) on delete cascade,
  from_user uuid not null references auth.users (id) on delete cascade,
  to_user uuid not null references auth.users (id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.expense_accounts enable row level security;
alter table public.expense_account_members enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_payments enable row level security;
revoke all on public.expense_accounts, public.expense_account_members, public.expenses, public.expense_payments from anon, authenticated;

-- ---------- Ayudantes ----------
create or replace function public.ex_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admin_users a where a.user_id = auth.uid());
$$;

create or replace function public.ex_member(p_user uuid)
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

revoke all on function public.ex_is_admin() from public, anon, authenticated;
revoke all on function public.ex_member(uuid) from public, anon, authenticated;

-- ---------- Leer todo ----------
create or replace function public.ex_state()
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
      'id', a.id,
      'title', a.title,
      'created_by', a.created_by,
      'created_at', a.created_at,
      'members', (
        select coalesce(jsonb_agg(public.ex_member(m.user_id)), '[]'::jsonb)
        from public.expense_account_members m where m.account_id = a.id
      ),
      'expenses', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', e.id, 'description', e.description, 'amount', e.amount, 'paid_by', e.paid_by,
          'split', to_jsonb(e.split), 'created_by', e.created_by, 'created_at', e.created_at
        ) order by e.created_at desc), '[]'::jsonb)
        from public.expenses e where e.account_id = a.id
      ),
      'payments', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', p.id, 'from', p.from_user, 'to', p.to_user, 'amount', p.amount,
          'created_by', p.created_by, 'created_at', p.created_at
        ) order by p.created_at desc), '[]'::jsonb)
        from public.expense_payments p where p.account_id = a.id
      )
    ) order by a.created_at desc)
    from public.expense_accounts a
  ), '[]'::jsonb);
end;
$$;

-- ---------- Cuentas ----------
create or replace function public.ex_create_account(p_title text, p_user_ids uuid[])
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_users uuid[];
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;

  select array_agg(distinct x) into v_users
  from unnest(p_user_ids || auth.uid()) as x
  where exists (select 1 from auth.users u where u.id = x);

  if coalesce(array_length(v_users, 1), 0) < 2 then
    raise exception 'Una cuenta necesita al menos 2 personas.';
  end if;

  insert into public.expense_accounts (title, created_by)
  values (left(btrim(p_title), 80), auth.uid())
  returning id into v_id;

  insert into public.expense_account_members (account_id, user_id)
  select v_id, x from unnest(v_users) as x;

  return v_id;
end;
$$;

create or replace function public.ex_delete_account(p_account_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.expense_accounts
  where id = p_account_id and (created_by = auth.uid() or public.ex_is_admin());
  if not found then
    raise exception 'Solo quien creó la cuenta o el admin pueden borrarla.';
  end if;
end;
$$;

-- ---------- Gastos ----------
create or replace function public.ex_add_expense(
  p_account_id uuid, p_description text, p_amount numeric, p_paid_by uuid, p_split uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_split uuid[];
begin
  if auth.uid() is null then
    raise exception 'Tenés que iniciar sesión.';
  end if;
  if not exists (select 1 from public.expense_account_members where account_id = p_account_id and user_id = auth.uid())
     and not public.ex_is_admin() then
    raise exception 'Solo quienes están en la cuenta pueden cargar gastos.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'El monto tiene que ser mayor a cero.';
  end if;
  if not exists (select 1 from public.expense_account_members where account_id = p_account_id and user_id = p_paid_by) then
    raise exception 'Quien pagó tiene que estar en la cuenta.';
  end if;

  select array_agg(distinct x) into v_split
  from unnest(p_split) as x
  where exists (select 1 from public.expense_account_members m where m.account_id = p_account_id and m.user_id = x);

  if coalesce(array_length(v_split, 1), 0) = 0 then
    raise exception 'Elegí entre quiénes se divide el gasto.';
  end if;

  insert into public.expenses (account_id, description, amount, paid_by, split, created_by)
  values (p_account_id, left(btrim(p_description), 80), round(p_amount, 2), p_paid_by, v_split, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.ex_delete_expense(p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.expenses
  where id = p_expense_id and (created_by = auth.uid() or public.ex_is_admin());
  if not found then
    raise exception 'Solo quien cargó el gasto o el admin pueden borrarlo.';
  end if;
end;
$$;

-- ---------- Pagos ----------
create or replace function public.ex_add_payment(p_account_id uuid, p_from uuid, p_to uuid, p_amount numeric)
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
  if auth.uid() not in (p_from, p_to) and not public.ex_is_admin() then
    raise exception 'Solo quien paga, quien cobra o el admin pueden marcar un pago.';
  end if;
  if p_from = p_to or p_amount is null or p_amount <= 0 then
    raise exception 'Pago inválido.';
  end if;
  if (select count(*) from public.expense_account_members
      where account_id = p_account_id and user_id in (p_from, p_to)) < 2 then
    raise exception 'Las dos personas tienen que estar en la cuenta.';
  end if;

  insert into public.expense_payments (account_id, from_user, to_user, amount, created_by)
  values (p_account_id, p_from, p_to, round(p_amount, 2), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.ex_delete_payment(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.expense_payments
  where id = p_payment_id
    and (auth.uid() in (from_user, to_user, created_by) or public.ex_is_admin());
  if not found then
    raise exception 'Solo quien paga, quien cobra o el admin pueden deshacer un pago.';
  end if;
end;
$$;

-- ---------- Permisos ----------
revoke all on function public.ex_state() from public, anon;
revoke all on function public.ex_create_account(text, uuid[]) from public, anon;
revoke all on function public.ex_delete_account(uuid) from public, anon;
revoke all on function public.ex_add_expense(uuid, text, numeric, uuid, uuid[]) from public, anon;
revoke all on function public.ex_delete_expense(uuid) from public, anon;
revoke all on function public.ex_add_payment(uuid, uuid, uuid, numeric) from public, anon;
revoke all on function public.ex_delete_payment(uuid) from public, anon;

grant execute on function public.ex_state() to authenticated;
grant execute on function public.ex_create_account(text, uuid[]) to authenticated;
grant execute on function public.ex_delete_account(uuid) to authenticated;
grant execute on function public.ex_add_expense(uuid, text, numeric, uuid, uuid[]) to authenticated;
grant execute on function public.ex_delete_expense(uuid) to authenticated;
grant execute on function public.ex_add_payment(uuid, uuid, uuid, numeric) to authenticated;
grant execute on function public.ex_delete_payment(uuid) to authenticated;
