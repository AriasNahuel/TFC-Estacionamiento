-- Cancelling a pending vehicle operation must also invalidate a command that
-- the physical controller has already acknowledged as running.
create or replace function public.cancel_operation(p_operation_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'administrator role required' using errcode='42501';
  end if;

  select * into v_op
  from public.vehicle_operations
  where id = p_operation_id
  for update;

  if not found or v_op.status not in ('pending','detected') then
    return;
  end if;

  update public.vehicle_operations
  set status = 'cancelled'
  where id = p_operation_id;

  update public.hardware_commands
  set status = 'cancelled'
  where operation_id = p_operation_id
    and status in ('pending','received','running');

  update public.parking_state
  set entry_gate = case when v_op.direction = 'entry' then 'closed' else entry_gate end,
      exit_gate = case when v_op.direction = 'exit' then 'closed' else exit_gate end,
      entry_sensor = case when v_op.direction = 'entry' then false else entry_sensor end,
      exit_sensor = case when v_op.direction = 'exit' then false else exit_sensor end,
      state_version = state_version + 1,
      updated_at = now()
  where id = 1;

  insert into public.audit_events(event_type,operation_id,source,result,actor_id)
  values('operation_cancelled',p_operation_id,v_op.source,'cancelled',auth.uid());
end $$;

revoke all on function public.cancel_operation(uuid) from public,anon,authenticated,service_role;
grant execute on function public.cancel_operation(uuid) to authenticated;
