begin;
select plan(14);

do $$
begin
  if exists (select 1 from public.vehicle_operations where status in ('pending','detected')) then
    raise exception 'test requires no active vehicle operations';
  end if;
  if exists (select 1 from public.hardware_commands where status in ('pending','received','running')) then
    raise exception 'test requires no active hardware commands';
  end if;
end;
$$;

insert into auth.users (id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,is_anonymous)
values
  ('00000000-0000-0000-0000-000000000113','authenticated','authenticated','manual-controls-admin@example.invalid','',now(),'{}'::jsonb,'{}'::jsonb,false),
  ('00000000-0000-0000-0000-000000000114','authenticated','authenticated','manual-controls-user@example.invalid','',now(),'{}'::jsonb,'{}'::jsonb,false)
on conflict (id) do nothing;
insert into public.user_roles (user_id,role)
values ('00000000-0000-0000-0000-000000000113','admin')
on conflict (user_id) do update set role=excluded.role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000113',true);

create temporary table manual_controls_counts on commit drop as
select regular_count,reserved_count,temporary_count,reserved_contingency_count
from public.parking_state where id=1;
create temporary table manual_controls_operations on commit drop as
select count(*) as operation_count from public.vehicle_operations;
update public.parking_state set simulation_mode=false where id=1;
update public.device_state
set connected=true,last_heartbeat=now(),
    state=coalesce(state,'{}'::jsonb) || jsonb_build_object('sensor_telemetry',jsonb_build_object(
      'entry_detected',false,'exit_detected',false,'updated_at',now()))
where device_id='esp8266-main';

select ok(not (select simulation_mode from public.parking_state where id=1), 'maintenance control is tested only in hardware mode');
select ok((select connected and last_heartbeat > now()-interval '30 seconds' from public.device_state where device_id='esp8266-main'), 'physical controller fixture is fresh');
select ok(not public.report_device_sensor_state('esp8266-main','invalid-development-secret',true,true), 'sensor telemetry rejects an invalid device credential');
select ok(not public.report_device_sensor_state('esp8266-main','invalid-development-secret',true,true,false,false,'off',false), 'extended lighting telemetry rejects an invalid device credential');

create temporary table manual_command_test on commit drop as
select public.queue_manual_hardware_command('white_on',null,'00000000-0000-0000-0000-000000000201') as id;
select ok((select id is not null from manual_command_test), 'administrator can enqueue an allowed lighting command');
select ok((select c.command_type='manual_control' and c.operation_id is null and c.payload->>'action'='white_on'
  from public.hardware_commands c cross join manual_command_test t where c.id=t.id), 'command has no vehicle operation or business payload');
select is(public.queue_manual_hardware_command('white_on',null,'00000000-0000-0000-0000-000000000201'),
  (select id from manual_command_test), 'same request id returns the original command');
select ok((select (regular_count,reserved_count,temporary_count,reserved_contingency_count) =
                  (select regular_count,reserved_count,temporary_count,reserved_contingency_count from manual_controls_counts)
  from public.parking_state where id=1)
  and (select count(*) from public.vehicle_operations)=(select operation_count from manual_controls_operations),
  'manual command does not create vehicle operations or change occupancy');
select throws_ok($$insert into public.vehicle_operations(direction,vehicle_type,status,source,idempotency_key,request_origin)
  values('entry','regular','pending','device','00000000-0000-0000-0000-000000000207','terminal')$$,
  '55000','maintenance command in progress','vehicle operation is serialized behind a queued maintenance command');

update public.hardware_commands set status='confirmed' where id=(select id from manual_command_test);
update public.device_state set state=state-'sensor_telemetry' where device_id='esp8266-main';
select throws_ok($$select public.queue_manual_hardware_command('white_off',null,'00000000-0000-0000-0000-000000000208')$$,
  '55000','sensor telemetry unavailable','maintenance controls reject an older firmware without sensor telemetry');
update public.device_state set state=jsonb_set(coalesce(state,'{}'::jsonb),'{sensor_telemetry}',
  jsonb_build_object('entry_detected',false,'exit_detected',false,'updated_at',now()),true) where device_id='esp8266-main';
update public.device_state set state=jsonb_set(jsonb_set(state,'{sensor_telemetry,entry_detected}','true'::jsonb,true),
  '{sensor_telemetry,updated_at}',to_jsonb(now()),true) where device_id='esp8266-main';
select throws_ok($$select public.queue_manual_hardware_command('barrier_close','entry','00000000-0000-0000-0000-000000000202')$$,
  '55000','sensor not confirmed clear','closing is rejected while its sensor detects an obstacle');
update public.device_state set state=jsonb_set(jsonb_set(state,'{sensor_telemetry,entry_detected}','false'::jsonb,true),
  '{sensor_telemetry,updated_at}',to_jsonb(now()-interval '31 seconds'),true) where device_id='esp8266-main';
select throws_ok($$select public.queue_manual_hardware_command('barrier_close','entry','00000000-0000-0000-0000-000000000203')$$,
  '55000','sensor not confirmed clear','closing is rejected when sensor telemetry is stale');

update public.device_state set state=jsonb_set(state,'{sensor_telemetry,updated_at}',to_jsonb(now()),true) where device_id='esp8266-main';
insert into public.vehicle_operations(direction,vehicle_type,status,source,idempotency_key,request_origin)
values('entry','regular','pending','device','00000000-0000-0000-0000-000000000204','terminal');
select throws_ok($$select public.queue_manual_hardware_command('rgb_red',null,'00000000-0000-0000-0000-000000000205')$$,
  '55000','vehicle operation in progress','maintenance command is rejected during a vehicle operation');

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000114',true);
select throws_ok($$select public.queue_manual_hardware_command('rgb_red',null,'00000000-0000-0000-0000-000000000206')$$,
  '42501','administrator role required','non-admin cannot enqueue physical maintenance commands');

select * from finish();
rollback;
