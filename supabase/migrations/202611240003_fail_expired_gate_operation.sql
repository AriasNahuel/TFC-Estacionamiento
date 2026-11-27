-- A controller rejection or an expired open_gate command must release the
-- pending vehicle operation without changing occupancy counters.
create or replace function public.ack_device_command(
  p_device_id text,
  p_device_secret text,
  p_command_id uuid,
  p_status text,
  p_result jsonb default '{}'::jsonb
)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_operation_id uuid;
  v_expires_at timestamptz;
  v_op public.vehicle_operations%rowtype;
  v_fail_operation boolean := false;
  v_expired_running_ack boolean := false;
  v_failure_event text;
begin
  if not private.authenticate_device(p_device_id,p_device_secret)
    or p_status not in ('running','confirmed','failed') then
    return false;
  end if;

  select c.operation_id, c.expires_at
  into v_operation_id, v_expires_at
  from public.hardware_commands c
  where c.id = p_command_id
    and c.device_id = p_device_id
    and c.status in ('received','running');

  if not found then
    return false;
  end if;

  v_expired_running_ack := p_status = 'running' and v_expires_at <= now();
  v_fail_operation := p_status = 'failed' or v_expired_running_ack;

  if v_fail_operation then
    if v_operation_id is not null then
      select * into v_op
      from public.vehicle_operations o
      where o.id = v_operation_id
      for update;
    end if;

    v_failure_event := case when v_expired_running_ack
      then 'open_gate_expired_before_running_ack'
      else 'device_reported_command_failure'
    end;

    update public.hardware_commands c
    set status = 'failed',
        acknowledged_at = now(),
        result = coalesce(p_result,'{}'::jsonb) || jsonb_build_object('event',v_failure_event)
    where c.id = p_command_id
      and c.device_id = p_device_id
      and c.status in ('received','running');

    if not found then
      return false;
    end if;

    if found and v_op.status in ('pending','detected') then
      update public.vehicle_operations
      set status = 'failed'
      where id = v_operation_id
        and status in ('pending','detected');

      update public.parking_state
      set entry_gate = case when v_op.direction = 'entry' then 'closed' else entry_gate end,
          exit_gate = case when v_op.direction = 'exit' then 'closed' else exit_gate end,
          entry_sensor = case when v_op.direction = 'entry' then false else entry_sensor end,
          exit_sensor = case when v_op.direction = 'exit' then false else exit_sensor end,
          state_version = state_version + 1,
          updated_at = now()
      where id = 1;

      insert into public.audit_events(event_type,operation_id,source,result,actor_id)
      values('operation_failed',v_operation_id,v_op.source,v_failure_event,null);
    end if;

    return not v_expired_running_ack;
  end if;

  update public.hardware_commands c
  set status = p_status,
      acknowledged_at = now(),
      result = coalesce(p_result,'{}'::jsonb)
  where c.id = p_command_id
    and c.device_id = p_device_id
    and c.status in ('received','running')
    and c.expires_at > now();

  return found;
end $$;

revoke all on function public.ack_device_command(text,text,uuid,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.ack_device_command(text,text,uuid,text,jsonb) to anon,authenticated;
