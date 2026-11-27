begin;
select plan(18);

-- Requiere el entorno sin operaciones en curso. Todas las filas se revierten.
do $$
begin
  if exists (select 1 from public.vehicle_operations where status in ('pending','detected')) then
    raise exception 'test requires no active vehicle operation';
  end if;
  if exists (select 1 from public.hardware_commands where status in ('pending','received','running')) then
    raise exception 'test requires no active hardware command';
  end if;
end;
$$;

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_anonymous)
values ('00000000-0000-0000-0000-000000000096', 'authenticated', 'authenticated', 'reservation-retention-test@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, false)
on conflict (id) do nothing;
insert into public.user_roles (user_id, role)
values ('00000000-0000-0000-0000-000000000096', 'admin')
on conflict (user_id) do update set role=excluded.role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000096',true);

-- Fixture reversible: aislar el cupo del día y dejar el controlador en hardware.
update public.reservations
set state='revoked',vehicle_present=false
where reserved_for=(now() at time zone 'America/Argentina/Cordoba')::date
  and state not in ('finished','revoked','expired');
update public.parking_state
set simulation_mode=false,reserved_count=0
where id=1;
update public.device_state
set connected=true,last_heartbeat=now()
where device_id='esp8266-main';

select ok((select simulation_mode=false from public.parking_state where id=1), 'regression runs in hardware mode');
select ok((select connected and last_heartbeat>now()-interval '30 seconds' from public.device_state where device_id='esp8266-main'), 'fixture supplies a fresh local controller heartbeat');

create temporary table reservation_test_date on commit drop as
select ((now() at time zone 'America/Argentina/Cordoba')::date + candidates.day_offset)::date as reserved_for
from generate_series(1000,5000) candidates(day_offset)
where not exists (
  select 1 from public.reservations r
  where r.reserved_for=(now() at time zone 'America/Argentina/Cordoba')::date+candidates.day_offset
    and r.state not in ('finished','revoked','expired')
)
order by candidates.day_offset limit 1;
create temporary table reservation_tokens on commit drop as
select candidates.n, created.reservation_id, created.access_token
from generate_series(1,3) candidates(n)
cross join reservation_test_date d
cross join lateral public.create_reservation(d.reserved_for) created;
update public.reservations r
set reserved_for=(now() at time zone 'America/Argentina/Cordoba')::date,
    state='available',vehicle_present=false
from reservation_tokens t where r.id=t.reservation_id;

select ok((select count(*)=3 from reservation_tokens), 'three reservation tokens are issued for the test date');
select ok((select count(*)=3 from public.reservations where reserved_for=(now() at time zone 'America/Argentina/Cordoba')::date and state not in ('finished','revoked','expired')), 'three reservations consume the daily quota');

create temporary table entry_operation on commit drop as
select private.begin_operation('entry','reserved',r.reservation_id,'finish',gen_random_uuid(),'device','terminal-entry') as operation_id
from reservation_tokens r where r.n=1;
select ok((select operation_id is not null from entry_operation), 'hardware business rules accept the valid reservation');
select ok((select o.source='device' and o.request_origin='terminal' and o.status='pending' and o.reservation_action='finish' from public.vehicle_operations o cross join entry_operation x where o.id=x.operation_id), 'entry is pending physical sensor confirmation');
select ok(not exists(select 1 from public.hardware_commands c cross join entry_operation x where c.operation_id=x.operation_id), 'regression does not enqueue a physical command');
select ok((select reserved_count=0 from public.parking_state where id=1), 'entry request alone does not occupy a reserved space');

update public.vehicle_operations o
set status='detected',sensor_released_at=clock_timestamp()-interval '600 milliseconds'
from entry_operation x where o.id=x.operation_id;
select private.confirm_controller_operation((select operation_id from entry_operation),500);
select ok((select reserved_count=1 from public.parking_state where id=1), 'confirmed entry increments physical reserved occupancy');
select ok((select r.state='parked' and r.vehicle_present from public.reservations r cross join reservation_tokens t where r.id=t.reservation_id and t.n=1), 'confirmed entry marks the reservation as occupied');

create temporary table exit_operation on commit drop as
select private.begin_operation('exit','reserved',r.reservation_id,'retain',gen_random_uuid(),'device','terminal-exit') as operation_id
from reservation_tokens r where r.n=1;
select ok((select operation_id is not null from exit_operation), 'hardware business rules accept the occupied reservation');
select ok((select o.reservation_action='retain' and o.status='pending' from public.vehicle_operations o cross join exit_operation x where o.id=x.operation_id), 'exit records the explicit retain choice');
select ok((select reserved_count=1 from public.parking_state where id=1), 'exit request alone does not release physical occupancy');

update public.vehicle_operations o
set status='detected',sensor_released_at=clock_timestamp()-interval '600 milliseconds'
from exit_operation x where o.id=x.operation_id;
select private.confirm_controller_operation((select operation_id from exit_operation),500);
select ok((select reserved_count=0 from public.parking_state where id=1), 'confirmed exit releases physical reserved occupancy');
select ok((select r.state='retained' and not r.vehicle_present from public.reservations r cross join reservation_tokens t where r.id=t.reservation_id and t.n=1), 'same-day retain keeps the reservation active after vehicle exit');
select ok((select count(*)=3 from public.reservations where reserved_for=(now() at time zone 'America/Argentina/Cordoba')::date and state not in ('finished','revoked','expired')), 'retained reservation still consumes one of three daily slots');
select throws_ok(
  format('select * from public.create_reservation(%L::date)',(now() at time zone 'America/Argentina/Cordoba')::date),
  '23514','daily reservation capacity reached','a fourth reservation is rejected after hardware retain'
);
select ok(not exists (select 1 from public.vehicle_operations where status in ('pending','detected')), 'test leaves no active operation');

select * from finish();
rollback;
