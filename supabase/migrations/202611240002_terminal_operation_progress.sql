-- Expose only the operation and gate-command progress to its linked terminal.
create or replace function public.get_terminal_operation_progress(
  p_terminal_id text,
  p_terminal_secret text,
  p_operation_id uuid
)
returns table(
  operation_id uuid,
  direction text,
  vehicle_type text,
  operation_status text,
  source text,
  command_status text,
  command_result jsonb
)
language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype;
begin
  select * into v_op
  from public.vehicle_operations o
  where o.id = p_operation_id;

  if not found
    or v_op.request_origin is distinct from 'terminal'
    or v_op.terminal_id is distinct from p_terminal_id
    or not private.authenticate_terminal(p_terminal_id, p_terminal_secret, v_op.direction) then
    return;
  end if;

  return query
  select o.id,
         o.direction,
         o.vehicle_type,
         o.status,
         o.source,
         command.status,
         command.result
  from public.vehicle_operations o
  left join lateral (
    select c.status, c.result
    from public.hardware_commands c
    where c.operation_id = o.id
      and c.command_type = 'open_gate'
    order by c.issued_at desc
    limit 1
  ) as command on true
  where o.id = p_operation_id;
end $$;

revoke all on function public.get_terminal_operation_progress(text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.get_terminal_operation_progress(text,text,uuid) to anon,authenticated;
