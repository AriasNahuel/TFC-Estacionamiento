begin;
select plan(31);

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_anonymous)
values
  ('00000000-0000-0000-0000-000000000301','authenticated','authenticated','reset-admin@example.invalid','',now(),'{}'::jsonb,'{}'::jsonb,false),
  ('00000000-0000-0000-0000-000000000302','authenticated','authenticated','reset-user@example.invalid','',now(),'{}'::jsonb,'{}'::jsonb,false)
on conflict (id) do nothing;
insert into public.user_roles(user_id,role)
values ('00000000-0000-0000-0000-000000000301','admin')
on conflict (user_id) do update set role=excluded.role;
update private.local_test_data_reset_guard set enabled=false where id=1;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000301',true);

-- Isolate backend-precondition tests from current local test history. The outer
-- transaction rolls these fixture removals back; the live rows are not committed.
delete from public.audit_events where operation_id is not null or reservation_id is not null
  or event_type like 'vehicle\_%' escape '\' or event_type like 'operation\_%' escape '\'
  or event_type like 'reservation\_%' escape '\';
delete from public.hardware_commands;
delete from public.vehicle_operations;

select ok(not has_function_privilege('anon','public.reset_local_test_data(boolean)','execute'),
  'anonymous clients cannot invoke the reset RPC');
select ok(has_function_privilege('authenticated','public.reset_local_test_data(boolean)','execute'),
  'authenticated clients can reach the RPC, which performs its own admin check');
select ok(position('delete from private.terminal_token_attempt_windows where terminal_id is not null'
  in pg_get_functiondef('public.reset_local_test_data(boolean)'::regprocedure)) > 0,
  'reservation-attempt cleanup has a safeupdate-compatible predicate');
select ok(position('delete from public.hardware_commands where id is not null'
  in pg_get_functiondef('public.reset_local_test_data(boolean)'::regprocedure)) > 0,
  'hardware-command cleanup has a safeupdate-compatible predicate');
select ok(position('delete from public.vehicle_operations where id is not null'
  in pg_get_functiondef('public.reset_local_test_data(boolean)'::regprocedure)) > 0,
  'vehicle-operation cleanup has a safeupdate-compatible predicate');
select ok(position('delete from public.reservations where id is not null'
  in pg_get_functiondef('public.reset_local_test_data(boolean)'::regprocedure)) > 0,
  'reservation cleanup has a safeupdate-compatible predicate');
select ok(not public.local_test_data_reset_enabled(),
  'the local-only backend guard is disabled by default');
select throws_ok($$select public.reset_local_test_data(true)$$,
  '55000','el restablecimiento de datos de prueba locales está deshabilitado en esta base',
  'administrator cannot reset while the local backend guard is disabled');

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000302',true);
select throws_ok($$select public.reset_local_test_data(true)$$,
  '42501','se requiere el rol de administrador',
  'non-admin is rejected even when the reset RPC is called directly');
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000301',true);
update private.local_test_data_reset_guard set enabled=true where id=1;
select ok(public.local_test_data_reset_enabled(),
  'the administrator can see when the local backend guard is enabled');
select throws_ok($$select public.reset_local_test_data(false)$$,
  '22023','confirmá que el estacionamiento físico esté vacío y ambas barreras cerradas',
  'the explicit physical-empty confirmation is required');

update public.parking_state
set simulation_mode=false, entry_gate='closed', exit_gate='closed', entry_sensor=false, exit_sensor=false,
    regular_count=2, reserved_count=1, temporary_count=1, reserved_contingency_count=1
where id=1;
update public.device_state
set connected=false, last_heartbeat=null,
    state='{"sensor_telemetry":{"entry_detected":false,"exit_detected":false,"updated_at":"2000-01-01T00:00:00Z"}}'::jsonb
where device_id='esp8266-main';
select throws_ok($$select public.reset_local_test_data(true)$$,
  '55000','el controlador activo está desconectado',
  'reset is rejected when the physical controller is disconnected');

update public.device_state
set connected=true,last_heartbeat=now()
where device_id='esp8266-main';
select throws_ok($$select public.reset_local_test_data(true)$$,
  '55000','la telemetría reciente debe confirmar libres ambos sensores físicos',
  'reset is rejected when either sensor is not confirmed clear');

update public.device_state
set state=jsonb_set(jsonb_set(state,'{sensor_telemetry,updated_at}',to_jsonb(now()),true),
                    '{sensor_telemetry,entry_detected}','true'::jsonb,true)
where device_id='esp8266-main';
update public.parking_state set entry_gate='open' where id=1;
select throws_ok($$select public.reset_local_test_data(true)$$,
  '55000','las barreras deben estar cerradas y ambos sensores libres',
  'reset is rejected when a barrier is not closed');

update public.parking_state set entry_gate='closed' where id=1;
update public.device_state
set state=jsonb_set(state,'{sensor_telemetry,entry_detected}','false'::jsonb,true)
where device_id='esp8266-main';
insert into public.vehicle_operations(direction,vehicle_type,status,source,idempotency_key,request_origin)
values('entry','regular','pending','device','00000000-0000-0000-0000-000000000303','terminal');
select throws_ok($$select public.reset_local_test_data(true)$$,
  '55000','hay una operación vehicular en curso',
  'reset is rejected during an active vehicle operation');
delete from public.vehicle_operations where idempotency_key='00000000-0000-0000-0000-000000000303';

insert into public.hardware_commands(device_id,command_type,payload,status,expires_at)
values('esp8266-main','manual_control','{"action":"white_on"}'::jsonb,'pending',now()+interval '60 seconds');
select throws_ok($$select public.reset_local_test_data(true)$$,
  '55000','hay un comando físico pendiente o en ejecución',
  'reset is rejected while a hardware command could still execute');
delete from public.hardware_commands where command_type='manual_control' and payload->>'action'='white_on';

-- Isolated happy-path fixtures inside this outer transaction: no DELETE below is
-- committed by this regression test. Rollback at the end restores the live data.
delete from public.audit_events where operation_id is not null or reservation_id is not null
  or event_type like 'vehicle\_%' escape '\' or event_type like 'operation\_%' escape '\'
  or event_type like 'reservation\_%' escape '\';
delete from public.hardware_commands;
delete from public.vehicle_operations;
delete from public.reservations;
delete from private.terminal_token_attempt_windows;

update public.parking_state
set simulation_mode=false, regular_count=2, reserved_count=1, temporary_count=1,
    reserved_contingency_count=1, entry_gate='closed', exit_gate='closed', entry_sensor=false, exit_sensor=false,
    night_mode=true, automatic_simulation=false, regular_capacity=7, reserved_capacity=3
where id=1;
update public.device_state
set connected=true,last_heartbeat=now(),
    state=jsonb_build_object('mode','physical','sensor_telemetry',jsonb_build_object(
      'entry_detected',false,'exit_detected',false,'ldr_night',true,'white_lights_on',true,
      'rgb_state','red','lighting_manual',false,'updated_at',now()))
where device_id='esp8266-main';
create temporary table reset_device_before on commit drop as
select connected,last_heartbeat,state from public.device_state where device_id='esp8266-main';
create temporary table reset_terminal on commit drop as
select * from public.provision_terminal('reset-test-entry','entry');
insert into private.terminal_token_attempt_windows(terminal_id,attempts)
select terminal_id,4 from reset_terminal;
create temporary table reset_reservation on commit drop as
select r.reservation_id from public.create_reservation((now() at time zone 'America/Argentina/Cordoba')::date) r;
insert into public.vehicle_operations(direction,vehicle_type,status,source,confirmed_at,idempotency_key,request_origin)
values('entry','regular','confirmed','device',now(),'00000000-0000-0000-0000-000000000304','terminal');
create temporary table reset_operation on commit drop as
select id from public.vehicle_operations where idempotency_key='00000000-0000-0000-0000-000000000304';
insert into public.hardware_commands(device_id,operation_id,command_type,payload,status,expires_at)
select 'esp8266-main',id,'open_gate','{"direction":"entry"}'::jsonb,'confirmed',now()+interval '60 seconds'
from reset_operation;
insert into public.hardware_commands(device_id,command_type,payload,status,issued_at,expires_at)
values('esp8266-main','manual_control','{"action":"white_on","fixture":"expired"}'::jsonb,
       'pending',now()-interval '2 minutes',now()-interval '1 minute');
insert into public.audit_events(event_type,vehicle_type,operation_id,source,result,actor_id)
select 'vehicle_entered','regular',id,'device','success','00000000-0000-0000-0000-000000000301' from reset_operation;
insert into public.audit_events(event_type,source,result,actor_id,details)
values('simulation_settings_changed','admin','success','00000000-0000-0000-0000-000000000301','{"test_fixture":true}'::jsonb);
create temporary table reset_result on commit drop as
select public.reset_local_test_data(true) as result;

select is((select (result->>'reservations_deleted')::integer from reset_result),1,
  'one reservation fixture was removed transactionally');
select is((select (result->>'tokens_hmac_deleted')::integer from reset_result),1,
  'the reservation HMAC was removed through its foreign key');
select is((select (result->>'tokens_encrypted_deleted')::integer from reset_result),1,
  'the encrypted token was removed through its foreign key');
select is((select (result->>'operations_deleted')::integer from reset_result),1,
  'the historical vehicle operation fixture was removed');
select is((select (result->>'commands_deleted')::integer from reset_result),2,
  'historical and expired, unclaimable commands were removed');
select ok(not exists(select 1 from public.reservations) and not exists(select 1 from public.vehicle_operations)
  and not exists(select 1 from public.hardware_commands),
  'reservations, vehicle operations, and commands are empty after the RPC');
select ok(not exists(select 1 from private.reservation_token_fingerprints)
  and not exists(select 1 from private.reservation_token_ciphertexts)
  and not exists(select 1 from private.terminal_token_attempt_windows),
  'token fingerprints, ciphertexts, and reservation-attempt windows are cleared');
select ok((select regular_count=0 and reserved_count=0 and temporary_count=0 and reserved_contingency_count=0
  and entry_gate='closed' and exit_gate='closed' and not entry_sensor and not exit_sensor
  from public.parking_state where id=1),
  'occupancy, contingency, barriers, and operational sensor mirrors are zeroed');
select ok((select not simulation_mode and night_mode and not automatic_simulation and regular_capacity=7 and reserved_capacity=3
  from public.parking_state where id=1),
  'hardware mode, lighting settings, automation, and capacities are preserved');
select ok((select d.connected and d.last_heartbeat=b.last_heartbeat and d.state=b.state
  from public.device_state d cross join reset_device_before b where d.device_id='esp8266-main'),
  'device connection and sensor/lighting telemetry are preserved');
select ok(exists(select 1 from public.terminals t join private.terminal_credentials c using(terminal_id)
  join reset_terminal r using(terminal_id) where t.enabled and t.revoked_at is null),
  'the terminal and its credential remain linked');
select ok(exists(select 1 from public.audit_events where event_type='simulation_settings_changed' and details->>'test_fixture'='true'),
  'administrative configuration audit is preserved');
select ok(exists(select 1 from public.user_roles where user_id='00000000-0000-0000-0000-000000000301' and role='admin'),
  'the administrator role is preserved');

create temporary table reset_new_reservations(reservation_id uuid) on commit drop;
do $$
declare
  i integer;
  v_created record;
begin
  for i in 1..3 loop
    select * into v_created
    from public.create_reservation((now() at time zone 'America/Argentina/Cordoba')::date);
    insert into reset_new_reservations(reservation_id) values(v_created.reservation_id);
  end loop;
end;
$$;
select is((select count(*)::integer from reset_new_reservations),3,
  'three new reservations can be created immediately after reset');
select throws_ok(
  $$select * from public.create_reservation((now() at time zone 'America/Argentina/Cordoba')::date)$$,
  '23514','daily reservation capacity reached',
  'a fourth reservation remains blocked by the daily backend capacity');

select * from finish();
rollback;
