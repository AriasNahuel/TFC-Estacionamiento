begin;
select plan(2);

select is(
  (select count(*)::integer from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='report_device_sensor_state' and p.pronargs=8),
  1,
  'extended telemetry RPC exists with the lighting fields'
);
select ok(
  not public.report_device_sensor_state('esp8266-main','invalid-development-secret',false,false,false,false,'off',false),
  'extended telemetry rejects an invalid device credential'
);

select * from finish();
rollback;
