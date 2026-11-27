-- Lectura mínima, autenticada por la credencial del dispositivo y acotada a sus
-- propios comandos. Permite que el firmware reconcilie Failed sin asumir que el
-- backend canceló o confirmó una operación.
create or replace function public.get_device_command_status(
  p_device_id text,
  p_device_secret text,
  p_command_id uuid
)
returns table (command_status text, operation_status text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.authenticate_device(p_device_id, p_device_secret) then
    return;
  end if;

  return query
    select c.status, o.status
    from public.hardware_commands c
    join public.vehicle_operations o on o.id = c.operation_id
    where c.id = p_command_id
      and c.device_id = p_device_id;
end;
$$;
revoke all on function public.get_device_command_status(text,text,uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_device_command_status(text,text,uuid) to anon, authenticated;
