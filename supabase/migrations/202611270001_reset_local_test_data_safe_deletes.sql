-- The authenticator session preloads Supabase's safeupdate guard. Add an
-- explicit non-null primary-key predicate to every intentional full-table
-- cleanup so the guard permits this admin-only reset RPC.
create or replace function public.reset_local_test_data(p_confirm_physical_empty boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parking public.parking_state%rowtype;
  v_device public.device_state%rowtype;
  v_device_id text;
  v_sensor_updated_at timestamptz;
  v_reservations integer := 0;
  v_operations integer := 0;
  v_commands integer := 0;
  v_audit_events integer := 0;
  v_token_attempt_windows integer := 0;
  v_hmac_tokens integer := 0;
  v_encrypted_tokens integer := 0;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'se requiere el rol de administrador' using errcode = '42501';
  end if;

  if not exists (
    select 1 from private.local_test_data_reset_guard g
    where g.id = 1 and g.enabled
  ) then
    raise exception 'el restablecimiento de datos de prueba locales está deshabilitado en esta base' using errcode = '55000';
  end if;

  if p_confirm_physical_empty is distinct from true then
    raise exception 'confirmá que el estacionamiento físico esté vacío y ambas barreras cerradas' using errcode = '22023';
  end if;

  -- Operation-creating RPCs lock this row before writing. Holding it serializes
  -- this transaction with new vehicle operations and manual hardware commands.
  select ps.* into v_parking
  from public.parking_state ps
  where ps.id = 1
  for update;
  if not found then
    raise exception 'la configuración del estacionamiento no está disponible' using errcode = '55000';
  end if;

  if v_parking.entry_gate <> 'closed' or v_parking.exit_gate <> 'closed'
     or v_parking.entry_sensor or v_parking.exit_sensor then
    raise exception 'las barreras deben estar cerradas y ambos sensores libres' using errcode = '55000';
  end if;

  if exists (select 1 from public.vehicle_operations o where o.status in ('pending', 'detected')) then
    raise exception 'hay una operación vehicular en curso' using errcode = '55000';
  end if;

  -- The ESP8266 claims only pending commands with expires_at > now(). Once this
  -- transaction holds the parking lock, no new operation can enqueue another.
  update public.hardware_commands c
  set status = 'failed', acknowledged_at = now(),
      result = jsonb_build_object('event','expired_before_local_test_reset')
  where c.status = 'pending' and c.expires_at <= now();

  if exists (
    select 1 from public.hardware_commands c
    where c.status in ('pending', 'received', 'running')
  ) then
    raise exception 'hay un comando físico pendiente o en ejecución' using errcode = '55000';
  end if;

  v_device_id := case when v_parking.simulation_mode then 'simulated-esp8266' else 'esp8266-main' end;
  select d.* into v_device
  from public.device_state d
  where d.device_id = v_device_id
  for update;
  if not found or not v_device.connected then
    raise exception 'el controlador activo está desconectado' using errcode = '55000';
  end if;

  if not v_parking.simulation_mode then
    if v_device.last_heartbeat is null or v_device.last_heartbeat <= now() - interval '30 seconds' then
      raise exception 'el heartbeat del controlador físico está vencido' using errcode = '55000';
    end if;
    v_sensor_updated_at := nullif(v_device.state->'sensor_telemetry'->>'updated_at', '')::timestamptz;
    if v_sensor_updated_at is null or v_sensor_updated_at <= now() - interval '30 seconds'
       or (v_device.state->'sensor_telemetry'->>'entry_detected')::boolean is distinct from false
       or (v_device.state->'sensor_telemetry'->>'exit_detected')::boolean is distinct from false then
      raise exception 'la telemetría reciente debe confirmar libres ambos sensores físicos' using errcode = '55000';
    end if;
  end if;

  select count(*) into v_hmac_tokens from private.reservation_token_fingerprints;
  select count(*) into v_encrypted_tokens from private.reservation_token_ciphertexts;
  delete from private.terminal_token_attempt_windows where terminal_id is not null;
  get diagnostics v_token_attempt_windows = row_count;

  delete from public.hardware_commands where id is not null;
  get diagnostics v_commands = row_count;

  delete from public.audit_events a
  where a.operation_id is not null
     or a.reservation_id is not null
     or a.event_type like 'vehicle\_%' escape '\'
     or a.event_type like 'operation\_%' escape '\'
     or a.event_type like 'reservation\_%' escape '\';
  get diagnostics v_audit_events = row_count;

  delete from public.vehicle_operations where id is not null;
  get diagnostics v_operations = row_count;

  delete from public.reservations where id is not null;
  get diagnostics v_reservations = row_count;

  update public.parking_state
  set regular_count = 0,
      reserved_count = 0,
      temporary_count = 0,
      reserved_contingency_count = 0,
      entry_gate = 'closed',
      exit_gate = 'closed',
      entry_sensor = false,
      exit_sensor = false,
      state_version = state_version + 1,
      updated_at = now()
  where id = 1;

  if exists (select 1 from public.reservations)
     or exists (select 1 from public.vehicle_operations)
     or exists (select 1 from public.hardware_commands)
     or exists (select 1 from private.reservation_token_fingerprints)
     or exists (select 1 from private.reservation_token_ciphertexts)
     or exists (select 1 from public.parking_state ps where ps.id = 1 and
       (ps.regular_count <> 0 or ps.reserved_count <> 0 or ps.temporary_count <> 0
        or ps.reserved_contingency_count <> 0 or ps.entry_gate <> 'closed' or ps.exit_gate <> 'closed'
        or ps.entry_sensor or ps.exit_sensor)) then
    raise exception 'falló la verificación de consistencia posterior al restablecimiento' using errcode = '55000';
  end if;

  return jsonb_build_object(
    'reservations_deleted', v_reservations,
    'tokens_hmac_deleted', v_hmac_tokens,
    'tokens_encrypted_deleted', v_encrypted_tokens,
    'operations_deleted', v_operations,
    'commands_deleted', v_commands,
    'audit_events_deleted', v_audit_events,
    'token_attempt_windows_deleted', v_token_attempt_windows,
    'regular_count', 0,
    'reserved_count', 0,
    'temporary_count', 0,
    'reserved_contingency_count', 0
  );
end;
$$;

revoke all on function public.reset_local_test_data(boolean) from public, anon, authenticated, service_role;
grant execute on function public.reset_local_test_data(boolean) to authenticated;
