begin;
select plan(50);

-- Usuario de prueba transaccional para ejecutar RPC administrativas. Todo se
-- revierte al final del archivo; no se crea una cuenta en el proyecto remoto.
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_anonymous)
values ('00000000-0000-0000-0000-000000000099', 'authenticated', 'authenticated', 'rpc-admin-test@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, false)
on conflict (id) do nothing;
insert into public.user_roles (user_id, role)
values ('00000000-0000-0000-0000-000000000099', 'admin')
on conflict (user_id) do update set role = excluded.role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000099', true);

-- Aislar las pruebas de la ocupación que exista en la base local; rollback restaura el estado.
update public.parking_state
set regular_count=0, reserved_count=0, temporary_count=0, reserved_contingency_count=0
where id=1;

select ok(
  not has_table_privilege('anon', 'public.reservations', 'select'),
  'anon cannot read reservation rows'
);
select ok(
  has_table_privilege('authenticated', 'public.reservations', 'select'),
  'authenticated role has only the grant needed for RLS-filtered admin reads'
);
select ok(
  has_schema_privilege('authenticated', 'public', 'usage'),
  'authenticated role can resolve explicitly granted public API objects'
);
select ok(
  not has_table_privilege('authenticated', 'public.user_roles', 'select'),
  'authenticated users cannot read or assign admin roles directly'
);
select ok(
  not has_table_privilege('authenticated', 'private.reservation_token_fingerprints', 'select'),
  'authenticated users cannot read HMAC fingerprints'
);
select ok(
  not has_table_privilege('service_role', 'private.reservation_token_fingerprints', 'select'),
  'service_role has no direct HMAC table grant'
);
select ok(
  not has_function_privilege('anon', 'public.create_reservation(date)', 'execute'),
  'anon cannot execute reservation creation'
);
select ok(
  has_function_privilege('authenticated', 'public.create_reservation(date)', 'execute'),
  'authenticated may call the RPC, which checks the admin role internally'
);
select ok(
  not has_function_privilege('authenticated', 'private.reservation_token_hmac(text)', 'execute'),
  'clients cannot invoke the HMAC helper'
);
select ok(
  not has_table_privilege('authenticated', 'vault.decrypted_secrets', 'select'),
  'authenticated users cannot read decrypted Vault secrets'
);
select ok(
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'reservations'
      and column_name in ('token_hash', 'token_hmac')
  ),
  'no token digest column is exposed on public reservation metadata'
);
select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
    where c.conrelid = 'private.reservation_token_fingerprints'::regclass
      and c.contype = 'u' and a.attname = 'token_hmac'
  ),
  'a database unique constraint serializes token fingerprint collisions across dates'
);
select ok(
  not has_table_privilege('anon', 'public.terminals', 'select'),
  'public clients cannot enumerate terminal identities'
);
select ok(
  not has_table_privilege('anon', 'private.terminal_credentials', 'select'),
  'terminal credential digests are private'
);
select ok(
  not has_table_privilege('anon', 'private.terminal_token_attempt_windows', 'select'),
  'terminal token attempt limits cannot be read or bypassed through table access'
);
select ok(
  has_table_privilege('anon', 'public.parking_state', 'select'),
  'anonymous clients can read the safe aggregate used by terminal screens'
);
select ok(
  not has_function_privilege('anon', 'public.create_reservation(date)', 'execute'),
  'anonymous clients cannot create reservations'
);
select ok(
  not has_function_privilege('anon', 'public.start_simulated_operation(text,text,text,text,uuid)', 'execute'),
  'anonymous clients cannot start simulator operations'
);
select ok(
  has_function_privilege('anon', 'public.start_terminal_operation(text,text,text,text,text,text,uuid)', 'execute'),
  'anonymous terminal RPC is callable only with a provisioned high-entropy credential'
);
select ok(
  has_function_privilege('anon', 'public.validate_terminal_credential(text,text,text)', 'execute')
  and has_function_privilege('authenticated', 'public.validate_terminal_credential(text,text,text)', 'execute'),
  'terminal credential validation is callable without exposing credential tables'
);
select ok(
  has_function_privilege('authenticated', 'public.is_current_admin()', 'execute'),
  'authenticated login can check its administrative role without reading user_roles'
);
select ok(
  not has_function_privilege('anon', 'private.authenticate_device(text,text)', 'execute'),
  'clients cannot invoke the private device credential checker directly'
);
select ok(
  not has_function_privilege('anon', 'public.provision_terminal(text,text)', 'execute'),
  'anonymous users cannot provision terminal credentials'
);
select ok(
  not has_function_privilege('anon', 'public.provision_device(text)', 'execute'),
  'anonymous users cannot provision ESP8266 credentials'
);
select ok(
  not has_table_privilege('authenticated', 'public.reservations', 'insert'),
  'authenticated clients cannot bypass reservation RPCs with direct inserts'
);
select ok(
  not has_table_privilege('anon', 'public.parking_state', 'update'),
  'public aggregate state is read-only to anonymous clients'
);

create temporary table test_device_provision_first on commit drop as
select * from public.provision_device('esp8266-main');
select ok((select length(device_secret)=64 from test_device_provision_first), 'provision_device executes and returns a one-time 256-bit secret');
select ok((select c.secret_digest=extensions.digest(convert_to(t.device_secret,'UTF8'),'sha256') from test_device_provision_first t join private.device_credentials c using (device_id)), 'provision_device stores only the secret digest');
update public.device_state set connected=true,last_heartbeat=now() where device_id='esp8266-main';
create temporary table test_device_provision_second on commit drop as
select * from public.provision_device('esp8266-main');
select ok((select t2.device_secret<>t1.device_secret and c.secret_digest=extensions.digest(convert_to(t2.device_secret,'UTF8'),'sha256') and c.secret_digest<>extensions.digest(convert_to(t1.device_secret,'UTF8'),'sha256') from test_device_provision_first t1 cross join test_device_provision_second t2 join private.device_credentials c on c.device_id=t2.device_id), 'provision_device conflict path rotates the credential digest');
select ok((select not connected from public.device_state where device_id='esp8266-main'), 'provision_device conflict path marks the old device session disconnected');

create temporary table test_terminal_provision_first on commit drop as
select * from public.provision_terminal('terminal-rpc-test','entry');
select ok((select length(terminal_secret)=64 from test_terminal_provision_first) and exists(select 1 from public.terminals where terminal_id='terminal-rpc-test' and lane='entry' and enabled), 'provision_terminal executes and creates terminal metadata');
select ok((select c.secret_digest=extensions.digest(convert_to(t.terminal_secret,'UTF8'),'sha256') from test_terminal_provision_first t join private.terminal_credentials c using (terminal_id)), 'provision_terminal stores only the secret digest');
create temporary table test_terminal_validation on commit drop as
select * from public.provision_terminal('terminal-validation-test','entry');
select ok((select public.validate_terminal_credential(terminal_id,terminal_secret,'entry') from test_terminal_validation), 'terminal credential validates for its provisioned lane');
select ok((select not public.validate_terminal_credential(terminal_id,terminal_secret,'exit') from test_terminal_validation), 'terminal credential is rejected for the other lane');
update public.terminals set lane='entry',enabled=false,revoked_at=now() where terminal_id='terminal-rpc-test';
insert into private.terminal_attempt_windows(terminal_id,failed_attempts) values('terminal-rpc-test',4);
insert into private.terminal_token_attempt_windows(terminal_id,attempts) values('terminal-rpc-test',4);
create temporary table test_terminal_provision_second on commit drop as
select * from public.provision_terminal('terminal-rpc-test','exit');
select ok(exists(select 1 from public.terminals where terminal_id='terminal-rpc-test' and lane='exit' and enabled and revoked_at is null), 'provision_terminal conflict path updates lane and reenables the terminal');
select ok((select t2.terminal_secret<>t1.terminal_secret and c.secret_digest=extensions.digest(convert_to(t2.terminal_secret,'UTF8'),'sha256') and c.secret_digest<>extensions.digest(convert_to(t1.terminal_secret,'UTF8'),'sha256') from test_terminal_provision_first t1 cross join test_terminal_provision_second t2 join private.terminal_credentials c on c.terminal_id=t2.terminal_id), 'provision_terminal conflict path rotates the credential digest');
select ok(not exists(select 1 from private.terminal_attempt_windows where terminal_id='terminal-rpc-test') and not exists(select 1 from private.terminal_token_attempt_windows where terminal_id='terminal-rpc-test'), 'provision_terminal conflict path clears previous rate-limit windows');

-- Flujo terminal -> controlador simulado -> confirmación transaccional.
create temporary table test_terminal_flow on commit drop as
select * from public.provision_terminal('terminal-entry-flow','entry');
select public.set_simulation_settings(false,true,false,true);
select ok((select public.start_terminal_operation(terminal_id,terminal_secret,'entry','regular',null,'finish',gen_random_uuid()) is null from test_terminal_flow), 'terminal is rejected when simulation mode is explicitly off and physical heartbeat is absent');
select public.set_simulation_settings(true,true,false,false);
select ok((select public.start_terminal_operation(terminal_id,terminal_secret,'entry','regular',null,'finish',gen_random_uuid()) is null from test_terminal_flow), 'terminal is rejected when simulated-esp8266 is disconnected');
select public.set_simulation_settings(true,true,false,true);
create temporary table test_terminal_operation on commit drop as
select f.terminal_id, f.terminal_secret,
  public.start_terminal_operation(f.terminal_id,f.terminal_secret,'entry','regular',null,'finish',gen_random_uuid()) as operation_id
from test_terminal_flow f;
select ok((select operation_id is not null from test_terminal_operation), 'connected simulator authorizes terminal operation');
select ok((select o.source='simulation' and o.request_origin='terminal' from public.vehicle_operations o join test_terminal_operation t on t.operation_id=o.id), 'operation records simulated controller and terminal request origin separately');
select ok(not exists(select 1 from public.hardware_commands c join test_terminal_operation t on t.operation_id=c.operation_id), 'simulated terminal operation creates no physical hardware command');
select ok(not exists(select 1 from public.device_state d where d.device_id='esp8266-main' and d.connected), 'simulated operation does not forge a physical heartbeat');
select set_config('test.terminal_flow_operation_id',(select operation_id::text from test_terminal_operation),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
select throws_ok(
  format('select public.simulate_sensor(%L::uuid,true,0)', current_setting('test.terminal_flow_operation_id')),
  '42501','administrator role required','terminal cannot control simulated sensor input'
);
select throws_ok(
  format('select public.complete_operation(%L::uuid,%L,%L,500)', current_setting('test.terminal_flow_operation_id'), 'terminal-entry-flow', 'not-a-controller-secret'),
  '42501','administrator role required','terminal cannot confirm a simulated movement by itself'
);
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000099',true);
select ok((select regular_count=0 from public.parking_state where id=1), 'unauthorized terminal confirmation leaves occupancy unchanged');
select public.simulate_sensor((select operation_id from test_terminal_operation),true,0);
select ok((select status='detected' from public.vehicle_operations o join test_terminal_operation t on t.operation_id=o.id), 'simulated controller reports vehicle detection');
select public.simulate_sensor((select operation_id from test_terminal_operation),false,500);
select ok((select regular_count=0 from public.parking_state where id=1), 'sensor release alone does not update occupancy before the stable interval');
select pg_sleep(0.55);
select public.finish_simulated_operation((select operation_id from test_terminal_operation));
select public.finish_simulated_operation((select operation_id from test_terminal_operation));
select ok((select regular_count=1 from public.parking_state where id=1), 'confirmed entry increments occupancy once even when finish RPC is repeated');
select ok((select count(*)=1 from public.audit_events a join test_terminal_operation t on t.operation_id=a.operation_id and a.event_type='vehicle_entered'), 'idempotent repeat creates only one movement audit event');

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
do $$
begin
  if private.is_admin() then
    raise exception 'an authenticated user without a user_roles row was incorrectly authorized';
  end if;
  if exists (select 1 from public.reservations) then
    raise exception 'an authenticated non-admin can read reservation rows';
  end if;
end;
$$;
reset role;

select * from finish();
rollback;
