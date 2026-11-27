begin;
select plan(19);

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

insert into auth.users (id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,is_anonymous)
values
  ('00000000-0000-0000-0000-000000000095','authenticated','authenticated','reservation-revoke-test@example.invalid','',now(),'{}'::jsonb,'{}'::jsonb,false),
  ('00000000-0000-0000-0000-000000000094','authenticated','authenticated','reservation-revoke-nonadmin@example.invalid','',now(),'{}'::jsonb,'{}'::jsonb,false)
on conflict (id) do nothing;
insert into public.user_roles (user_id,role)
values ('00000000-0000-0000-0000-000000000095','admin')
on conflict (user_id) do update set role=excluded.role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000095',true);

create temporary table revoke_test_counts on commit drop as
select regular_count,reserved_count,temporary_count,reserved_contingency_count
from public.parking_state where id=1;
create temporary table revoke_test_reservations (
  scenario text primary key,
  reservation_id uuid not null,
  token text
) on commit drop;
insert into revoke_test_reservations values
  ('simulation',gen_random_uuid(),null),
  ('hardware',gen_random_uuid(),'008731'),
  ('occupied',gen_random_uuid(),null);

insert into public.reservations (id,token_suffix,reserved_for,state,vehicle_present,created_by)
select reservation_id,
       case scenario when 'simulation' then '101' when 'hardware' then right(token,3) else '103' end,
       (now() at time zone 'America/Argentina/Cordoba')::date,
       case when scenario='occupied' then 'parked' else 'available' end,
       scenario='occupied',
       '00000000-0000-0000-0000-000000000095'
from revoke_test_reservations;

insert into private.reservation_token_fingerprints(reservation_id,token_hmac)
select reservation_id,private.reservation_token_hmac(token)
from revoke_test_reservations where scenario='hardware';

create temporary table revoke_test_terminal on commit drop as
select * from public.provision_terminal('reservation-revoke-test-entry','entry');

update public.device_state set connected=false where device_id in ('simulated-esp8266','esp8266-main');
update public.parking_state set simulation_mode=true where id=1;
select ok((select simulation_mode from public.parking_state where id=1), 'simulation fixture is active');
select ok(not exists(select 1 from public.device_state where device_id='simulated-esp8266' and connected), 'simulator is disconnected');
select lives_ok(
  format('select public.revoke_reservation(%L::uuid)',(select reservation_id from revoke_test_reservations where scenario='simulation')),
  'admin can revoke in simulation mode without a connected simulator'
);
select ok((select state='revoked' and sync_status='confirmed' and version=2 from public.reservations where id=(select reservation_id from revoke_test_reservations where scenario='simulation')),
  'simulation revocation marks the reservation revoked and advances its version');
select ok(exists(select 1 from public.audit_events where event_type='reservation_revoked' and reservation_id=(select reservation_id from revoke_test_reservations where scenario='simulation') and source='admin' and result='success'),
  'simulation revocation writes its admin audit event');

update public.parking_state set simulation_mode=false where id=1;
select ok(not (select simulation_mode from public.parking_state where id=1), 'hardware fixture is active');
select ok(not exists(select 1 from public.device_state where device_id='simulated-esp8266' and connected), 'simulator remains disconnected in hardware mode');
select lives_ok(
  format('select public.revoke_reservation(%L::uuid)',(select reservation_id from revoke_test_reservations where scenario='hardware')),
  'admin can revoke in hardware mode without a connected simulator or physical device'
);
select ok((select state='revoked' and sync_status='confirmed' and version=2 from public.reservations where id=(select reservation_id from revoke_test_reservations where scenario='hardware')),
  'hardware revocation marks the reservation revoked and advances its version');
select ok(exists(select 1 from public.audit_events where event_type='reservation_revoked' and reservation_id=(select reservation_id from revoke_test_reservations where scenario='hardware') and source='admin' and result='success'),
  'hardware revocation writes its admin audit event');

select throws_ok(
  format('select public.revoke_reservation(%L::uuid)',(select reservation_id from revoke_test_reservations where scenario='occupied')),
  '55000','cannot revoke a reservation while its vehicle is present',
  'admin cannot revoke while the reserved vehicle is present'
);
select ok((select state='parked' and vehicle_present from public.reservations where id=(select reservation_id from revoke_test_reservations where scenario='occupied')),
  'rejected revocation leaves the occupied reservation unchanged');
select ok(not exists(select 1 from public.audit_events where event_type='reservation_revoked' and reservation_id=(select reservation_id from revoke_test_reservations where scenario='occupied')),
  'rejected revocation does not write a success audit event');

select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000094',true);
select throws_ok(
  format('select public.revoke_reservation(%L::uuid)',(select reservation_id from revoke_test_reservations where scenario='simulation')),
  '42501','administrator role required',
  'non-admin remains unable to revoke a reservation'
);
select ok((select state='revoked' from public.reservations where id=(select reservation_id from revoke_test_reservations where scenario='simulation')),
  'unauthorized revoke leaves the already-revoked reservation unchanged');

-- The HMAC still resolves to this row, but the revoked state must reject entry.
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000095',true);
update public.device_state set connected=true,last_heartbeat=now() where device_id='esp8266-main';
select ok((
  select public.start_terminal_operation(t.terminal_id,t.terminal_secret,'entry','reserved',r.token,'finish',gen_random_uuid()) is null
  from revoke_test_terminal t cross join revoke_test_reservations r where r.scenario='hardware'
), 'a valid token HMAC for a revoked reservation cannot start a future entry');
select ok(not exists(select 1 from public.vehicle_operations where reservation_id=(select reservation_id from revoke_test_reservations where scenario='hardware')),
  'revoked token rejection creates no vehicle operation');
select ok(not exists(select 1 from public.hardware_commands where operation_id in (select id from public.vehicle_operations where reservation_id=(select reservation_id from revoke_test_reservations where scenario='hardware'))),
  'revoked token rejection creates no hardware command');
select ok(exists (
  select 1 from public.parking_state p cross join revoke_test_counts before
  where (p.regular_count,p.reserved_count,p.temporary_count,p.reserved_contingency_count)=
        (before.regular_count,before.reserved_count,before.temporary_count,before.reserved_contingency_count)
), 'revocation leaves every occupancy counter unchanged');

select * from finish();
rollback;
