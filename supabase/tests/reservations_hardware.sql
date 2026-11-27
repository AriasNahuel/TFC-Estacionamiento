begin;
select plan(14);

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_anonymous)
values ('00000000-0000-0000-0000-000000000098', 'authenticated', 'authenticated', 'reservation-hardware-test@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, false)
on conflict (id) do nothing;
insert into public.user_roles (user_id, role)
values ('00000000-0000-0000-0000-000000000098', 'admin')
on conflict (user_id) do update set role = excluded.role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000098', true);

-- Simula modo físico sin un simulador disponible. Todo se revierte al final.
update public.parking_state
set simulation_mode = false, regular_count = 0, reserved_count = 0,
    temporary_count = 0, reserved_contingency_count = 0
where id = 1;
update public.device_state set connected = false where device_id = 'simulated-esp8266';
insert into public.device_state (device_id, connected, last_heartbeat, state)
values ('esp8266-main', true, now(), '{"mode":"physical","test":true}'::jsonb)
on conflict (device_id) do update
set connected = true, last_heartbeat = now(), state = excluded.state;

select ok((select not simulation_mode from public.parking_state where id = 1),
  'regression runs in hardware mode');
select ok(not exists (select 1 from public.device_state where device_id = 'simulated-esp8266' and connected),
  'reservation creation does not depend on the simulated controller');

create temporary table reservation_test_date on commit drop as
select ((now() at time zone 'America/Argentina/Cordoba')::date + candidates.day_offset)::date as reserved_for
from generate_series(1000, 5000) as candidates(day_offset)
where (select count(*) from public.reservations r where r.reserved_for=(now() at time zone 'America/Argentina/Cordoba')::date + candidates.day_offset and r.state not in ('finished','revoked','expired')) <= 1
order by candidates.day_offset limit 1;
create temporary table reservation_one on commit drop as
select r.* from reservation_test_date d cross join lateral public.create_reservation(d.reserved_for) r;
create temporary table reservation_two on commit drop as
select r.* from reservation_test_date d cross join lateral public.create_reservation(d.reserved_for) r;
update public.reservations actual
set reserved_for = (now() at time zone 'America/Argentina/Cordoba')::date, state = 'available'
from reservation_one x where actual.id = x.reservation_id;
update reservation_one
set reserved_for = (now() at time zone 'America/Argentina/Cordoba')::date;

select ok(
  (select access_token ~ '^[0-9]{6}$' from reservation_one),
  'hardware mode reservation returns a six-digit token'
);
select ok(
  (select r.sync_status = 'confirmed' and r.synced_at is not null
   from reservation_one x join public.reservations r on r.id = x.reservation_id),
  'local database transaction confirms the reservation in hardware mode'
);
select ok(
  (select f.token_hmac = private.reservation_token_hmac(x.access_token)
   from reservation_one x join private.reservation_token_fingerprints f using (reservation_id)),
  'only the HMAC fingerprint is persisted for the returned token'
);
select ok(
  (select a.access_token <> b.access_token from reservation_one a cross join reservation_two b),
  'independent reservations receive distinct tokens'
);
select ok(
  (select count(distinct f.token_hmac) = 2
   from (select reservation_id from reservation_one union all select reservation_id from reservation_two) ids
   join private.reservation_token_fingerprints f using (reservation_id)),
  'global unique token fingerprints are persisted'
);

create temporary table entry_terminal on commit drop as
select * from public.provision_terminal('reservation-test-entry', 'entry');
select ok(
  (select count(*) = 1
   from entry_terminal t cross join reservation_one r
   cross join lateral public.inspect_terminal_reservation(t.terminal_id, t.terminal_secret, r.access_token) inspected
   where inspected.reservation_id = r.reservation_id and inspected.reserved_for = r.reserved_for),
  'entry terminal can inspect the new hardware-mode reservation token'
);

create temporary table terminal_operation on commit drop as
select public.start_terminal_operation(
  t.terminal_id, t.terminal_secret, 'entry', 'reserved', r.access_token, 'finish',
  '00000000-0000-0000-0000-000000000098'::uuid
) as operation_id
from entry_terminal t cross join reservation_one r;
select ok((select operation_id is not null from terminal_operation),
  'entry terminal can submit the confirmed reservation to the hardware controller');
select ok(
  (select exists (
    select 1 from public.vehicle_operations o cross join terminal_operation op cross join reservation_one r
    where o.id = op.operation_id and o.reservation_id = r.reservation_id
      and o.source = 'device' and o.request_origin = 'terminal' and o.status = 'pending'
  )),
  'terminal operation is linked to the reservation and remains pending sensor confirmation'
);
select ok(
  (select exists (
    select 1 from public.hardware_commands c cross join terminal_operation op
    where c.operation_id = op.operation_id and c.device_id = 'esp8266-main'
      and c.command_type = 'open_gate' and c.status = 'pending'
  )),
  'hardware command is queued transactionally for the ESP8266'
);
select ok(
  (select c.payload->>'direction' = 'entry' and c.payload->>'vehicle_type' = 'reserved'
   from public.hardware_commands c cross join terminal_operation op
   where c.operation_id = op.operation_id and c.command_type = 'open_gate'),
  'authorized reserved vehicle type reaches the device command payload'
);
select ok(
  (select not exists (
    select 1 from public.vehicle_operations o cross join terminal_operation op
    where o.id = op.operation_id and o.status = 'confirmed'
  )),
  'creating and validating the token does not confirm a vehicle passage'
);
select ok(
  (select not exists (
    select 1 from public.reservations r cross join reservation_one x
    where r.id = x.reservation_id and r.vehicle_present
  )),
  'the reservation stays unoccupied until the physical sensor sequence completes'
);

select * from finish();
rollback;
