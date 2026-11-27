-- Reuse device_state for authenticated sensor telemetry and hardware_commands
-- for administrator maintenance controls. No vehicle row or counter is written.
create or replace function public.report_device_sensor_state(
  p_device_id text,
  p_device_secret text,
  p_entry_detected boolean,
  p_exit_detected boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated_at timestamptz := clock_timestamp();
begin
  if p_device_id <> 'esp8266-main'
     or not private.authenticate_device(p_device_id,p_device_secret)
     or p_entry_detected is null
     or p_exit_detected is null then
    return false;
  end if;

  update public.device_state
  set connected = true,
      last_heartbeat = v_updated_at,
      updated_at = v_updated_at,
      state = coalesce(state,'{}'::jsonb) || jsonb_build_object(
        'sensor_telemetry', jsonb_build_object(
          'entry_detected', p_entry_detected,
          'exit_detected', p_exit_detected,
          'updated_at', v_updated_at
        )
      )
  where device_id = p_device_id;

  return found;
end;
$$;
revoke all on function public.report_device_sensor_state(text,text,boolean,boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.report_device_sensor_state(text,text,boolean,boolean)
  to anon, authenticated;

create or replace function public.queue_manual_hardware_command(
  p_action text,
  p_target text,
  p_request_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command_id uuid;
  v_mode boolean;
  v_device public.device_state%rowtype;
  v_sensor_detected boolean;
  v_sensor_updated_at timestamptz;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'administrator role required' using errcode='42501';
  end if;
  if p_request_id is null then
    raise exception 'request id required' using errcode='22023';
  end if;
  if p_action is null
     or p_action not in ('barrier_open','barrier_close','white_on','white_off','rgb_red','rgb_green','rgb_off','lighting_auto')
     or (p_action in ('barrier_open','barrier_close') and coalesce(p_target not in ('entry','exit'),true))
     or (p_action not in ('barrier_open','barrier_close') and p_target is not null) then
    raise exception 'invalid maintenance command' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  select c.id into v_command_id
  from public.hardware_commands c
  where c.device_id = 'esp8266-main'
    and c.command_type = 'manual_control'
    and c.payload->>'request_id' = p_request_id::text;
  if v_command_id is not null then
    return v_command_id;
  end if;

  select ps.simulation_mode into v_mode
  from public.parking_state ps where ps.id = 1 for update;
  if not found or v_mode then
    raise exception 'physical hardware mode required' using errcode='55000';
  end if;

  select d.* into v_device
  from public.device_state d where d.device_id = 'esp8266-main';
  if not found or not v_device.connected or v_device.last_heartbeat is null
     or v_device.last_heartbeat <= now() - interval '30 seconds' then
    raise exception 'esp8266 controller unavailable' using errcode='55000';
  end if;

  if exists (select 1 from public.vehicle_operations o where o.status in ('pending','detected')) then
    raise exception 'vehicle operation in progress' using errcode='55000';
  end if;

  update public.hardware_commands c
  set status = 'failed', acknowledged_at = now(),
      result = jsonb_build_object('event','expired_before_execution')
  where c.device_id = 'esp8266-main' and c.command_type = 'manual_control'
    and c.status in ('pending','received') and c.expires_at <= now();

  if exists (
    select 1 from public.hardware_commands c
    where c.device_id = 'esp8266-main' and c.command_type = 'manual_control'
      and c.status in ('pending','received','running') and c.expires_at > now()
  ) then
    raise exception 'another maintenance command is active' using errcode='55000';
  end if;

  if p_action = 'barrier_close' then
    v_sensor_updated_at := nullif(v_device.state->'sensor_telemetry'->>'updated_at','')::timestamptz;
    v_sensor_detected := (v_device.state->'sensor_telemetry'->>(p_target || '_detected'))::boolean;
    if v_sensor_updated_at is null or v_sensor_updated_at <= now() - interval '30 seconds'
       or v_sensor_detected is distinct from false then
      raise exception 'sensor not confirmed clear' using errcode='55000';
    end if;
  end if;

  insert into public.hardware_commands(device_id,operation_id,command_type,payload,expires_at)
  values (
    'esp8266-main', null, 'manual_control',
    jsonb_build_object('action',p_action,'target',p_target,'request_id',p_request_id),
    now() + interval '60 seconds'
  ) returning id into v_command_id;

  return v_command_id;
end;
$$;
revoke all on function public.queue_manual_hardware_command(text,text,uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.queue_manual_hardware_command(text,text,uuid)
  to authenticated;

do $$
begin
  if exists (select 1 from pg_publication_tables where pubname='supabase_realtime'
             and schemaname='public' and tablename='hardware_commands') then
    return;
  end if;
  alter publication supabase_realtime add table public.hardware_commands;
end;
$$;
