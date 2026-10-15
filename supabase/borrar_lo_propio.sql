-- Cada integrante puede borrar SOLO lo que creó.
-- El administrador sigue pudiendo borrar todo (eso ya lo permiten las
-- reglas que tenías; estas se suman a ellas).
-- Pegar y ejecutar UNA vez en Supabase → SQL Editor.

-- Propuestas
drop policy if exists "Borrar mis propuestas" on public.proposals;
create policy "Borrar mis propuestas" on public.proposals
  for delete to authenticated
  using (proposed_by = auth.uid());

-- Eventos del calendario
drop policy if exists "Borrar mis eventos" on public.calendar_events;
create policy "Borrar mis eventos" on public.calendar_events
  for delete to authenticated
  using (created_by = auth.uid());

-- Enlaces
drop policy if exists "Borrar mis enlaces" on public.shared_links;
create policy "Borrar mis enlaces" on public.shared_links
  for delete to authenticated
  using (created_by = auth.uid());

-- Votaciones (al borrarla se borran también sus opciones y votos)
drop policy if exists "Borrar mis votaciones" on public.polls;
create policy "Borrar mis votaciones" on public.polls
  for delete to authenticated
  using (created_by = auth.uid());
