-- Extend the existing authenticated device telemetry with the effective LDR
-- and lighting outputs. The 4-argument RPC remains available to older clients.
create or replace function public.report_device_sensor_state(
  p_device_id text,
  p_device_secret text,
  p_entry_detected boolean,
  p_exit_detected boolean,
  p_ldr_night boolean,
  p_white_lights_on boolean,
  p_rgb_state text,
  p_lighting_manual boolean
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
     or p_exit_detected is null
     or p_ldr_night is null
     or p_white_lights_on is null
     or p_lighting_manual is null
     or p_rgb_state is null
     or p_rgb_state not in ('off','red','green') then
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
          'ldr_night', p_ldr_night,
          'white_lights_on', p_white_lights_on,
          'rgb_state', p_rgb_state,
          'lighting_manual', p_lighting_manual,
          'updated_at', v_updated_at
        )
      )
  where device_id = p_device_id;

  return found;
end;
$$;
revoke all on function public.report_device_sensor_state(text,text,boolean,boolean,boolean,boolean,text,boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.report_device_sensor_state(text,text,boolean,boolean,boolean,boolean,text,boolean)
  to anon, authenticated;
