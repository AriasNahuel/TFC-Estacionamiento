-- Do not send any physical maintenance action to firmware that has not started
-- reporting both lane sensors. This also protects inserts outside the RPC.
create or replace function private.require_fresh_maintenance_telemetry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb;
  v_updated_at timestamptz;
begin
  if new.command_type <> 'manual_control' then return new; end if;
  select d.state into v_state from public.device_state d
  where d.device_id=new.device_id and d.connected
    and d.last_heartbeat > now()-interval '30 seconds';
  if not found then
    raise exception 'esp8266 controller unavailable' using errcode='55000';
  end if;
  v_updated_at := nullif(v_state->'sensor_telemetry'->>'updated_at','')::timestamptz;
  if v_updated_at is null or v_updated_at <= now()-interval '30 seconds'
     or v_state->'sensor_telemetry'->>'entry_detected' is null
     or v_state->'sensor_telemetry'->>'exit_detected' is null then
    raise exception 'sensor telemetry unavailable' using errcode='55000';
  end if;
  return new;
end;
$$;
revoke all on function private.require_fresh_maintenance_telemetry() from public,anon,authenticated,service_role;

drop trigger if exists require_fresh_maintenance_telemetry on public.hardware_commands;
create trigger require_fresh_maintenance_telemetry
before insert on public.hardware_commands
for each row execute function private.require_fresh_maintenance_telemetry();
