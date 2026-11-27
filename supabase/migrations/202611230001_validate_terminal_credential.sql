-- Validación explícita de credenciales de terminal antes de guardarlas en la sesión.
create or replace function public.validate_terminal_credential(
  p_terminal_id text,
  p_terminal_secret text,
  p_lane text
)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select coalesce(
    p_lane in ('entry', 'exit')
      and private.authenticate_terminal(p_terminal_id, p_terminal_secret, p_lane),
    false
  );
$$;

revoke all on function public.validate_terminal_credential(text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.validate_terminal_credential(text, text, text) to anon, authenticated;
