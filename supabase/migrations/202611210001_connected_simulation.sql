-- Integración central compartida y preparación de sesiones de terminal.
-- La migración inicial ya fue aplicada y permanece inmutable.

alter table public.parking_state
  add column if not exists reserved_contingency_count integer not null default 0 check (reserved_contingency_count between 0 and 3),
  add column if not exists state_version bigint not null default 1,
  add column if not exists entry_gate text not null default 'closed',
  add column if not exists exit_gate text not null default 'closed',
  add column if not exists entry_sensor boolean not null default false,
  add column if not exists exit_sensor boolean not null default false,
  add column if not exists night_mode boolean not null default false,
  add column if not exists automatic_simulation boolean not null default true,
  add column if not exists regular_capacity integer not null default 7 check (regular_capacity = 7),
  add column if not exists reserved_capacity integer not null default 3 check (reserved_capacity = 3);

alter table public.vehicle_operations
  add column if not exists sensor_detected_at timestamptz,
  add column if not exists sensor_released_at timestamptz,
  add column if not exists sensor_clear_ms integer,
  add column if not exists terminal_id text;

create unique index if not exists hardware_commands_one_gate_open_per_operation on public.hardware_commands(operation_id)
  where operation_id is not null and command_type='open_gate';

alter table public.reservations
  add column if not exists sync_status text not null default 'confirmed' check (sync_status in ('pending','confirmed','failed')),
  add column if not exists version bigint not null default 1,
  add column if not exists synced_at timestamptz;

create table if not exists public.terminals (
  terminal_id text primary key check (terminal_id ~ '^[a-zA-Z0-9_-]{3,64}$'),
  lane text not null check (lane in ('entry','exit')),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  last_seen_at timestamptz
);
create table if not exists private.terminal_credentials (
  terminal_id text primary key references public.terminals(terminal_id) on delete cascade,
  secret_digest bytea not null,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists private.terminal_attempt_windows (
  terminal_id text primary key references public.terminals(terminal_id) on delete cascade,
  window_started_at timestamptz not null default now(),
  failed_attempts integer not null default 0,
  blocked_until timestamptz
);
create table if not exists private.terminal_token_attempt_windows (
  terminal_id text primary key references public.terminals(terminal_id) on delete cascade,
  window_started_at timestamptz not null default now(),
  attempts integer not null default 0,
  blocked_until timestamptz
);
create table if not exists private.device_credentials (
  device_id text primary key references public.device_state(device_id) on delete cascade,
  secret_digest bytea not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);
revoke all on private.terminal_credentials, private.terminal_attempt_windows, private.terminal_token_attempt_windows, private.device_credentials from public, anon, authenticated, service_role;
alter table private.terminal_credentials enable row level security;
alter table private.terminal_attempt_windows enable row level security;
alter table private.terminal_token_attempt_windows enable row level security;
alter table private.device_credentials enable row level security;
alter table public.terminals enable row level security;
create policy "admins manage terminals" on public.terminals for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));

-- La API pública sólo necesita un agregado de ocupación; no contiene reservas,
-- huellas, credenciales ni eventos de auditoría.
create policy "public read safe parking aggregate" on public.parking_state
  for select to anon, authenticated using (true);
grant select on public.parking_state to anon;
grant select, insert, update, delete on public.terminals to authenticated;

-- El simulador central está expresamente separado del hardware real. Al estar
-- activo se considera disponible para confirmar reservas simuladas.
insert into public.device_state (device_id, connected, state)
values ('simulated-esp8266', true, '{"mode":"simulation","sync_version":1}'::jsonb)
on conflict (device_id) do update set connected = true, updated_at = now();

create or replace function private.authenticate_terminal(p_terminal_id text, p_secret text, p_lane text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_digest bytea; v_row private.terminal_attempt_windows%rowtype;
begin
  if p_terminal_id is null or p_secret is null or length(p_secret) < 40 then return false; end if;
  if not exists(select 1 from public.terminals where terminal_id=p_terminal_id) then return false; end if;
  select * into v_row from private.terminal_attempt_windows where terminal_id = p_terminal_id for update;
  if found and v_row.blocked_until > now() then return false; end if;
  select tc.secret_digest into v_digest
  from private.terminal_credentials tc join public.terminals t using (terminal_id)
  where tc.terminal_id = p_terminal_id and t.enabled and t.revoked_at is null
    and t.lane = p_lane and (tc.expires_at is null or tc.expires_at > now());
  if v_digest is not null and v_digest = extensions.digest(convert_to(p_secret, 'UTF8'), 'sha256') then
    insert into private.terminal_attempt_windows(terminal_id,window_started_at,failed_attempts,blocked_until)
      values(p_terminal_id,now(),0,null)
      on conflict(terminal_id) do update set window_started_at=now(),failed_attempts=0,blocked_until=null;
    update public.terminals set last_seen_at=now() where terminal_id=p_terminal_id;
    return true;
  end if;
  insert into private.terminal_attempt_windows(terminal_id,window_started_at,failed_attempts,blocked_until)
    values(p_terminal_id,now(),1,null)
    on conflict(terminal_id) do update set
      failed_attempts=case when private.terminal_attempt_windows.window_started_at < now()-interval '1 minute' then 1 else private.terminal_attempt_windows.failed_attempts+1 end,
      window_started_at=case when private.terminal_attempt_windows.window_started_at < now()-interval '1 minute' then now() else private.terminal_attempt_windows.window_started_at end,
      blocked_until=case when private.terminal_attempt_windows.window_started_at < now()-interval '1 minute' then null when private.terminal_attempt_windows.failed_attempts+1 >= 5 then now()+interval '1 minute' else private.terminal_attempt_windows.blocked_until end;
  return false;
end $$;
revoke all on function private.authenticate_terminal(text,text,text) from public,anon,authenticated,service_role;

create or replace function private.allow_terminal_token_attempt(p_terminal_id text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v private.terminal_token_attempt_windows%rowtype;
begin
  insert into private.terminal_token_attempt_windows(terminal_id) values(p_terminal_id) on conflict do nothing;
  select * into v from private.terminal_token_attempt_windows where terminal_id=p_terminal_id for update;
  if v.blocked_until>now() then return false; end if;
  if v.window_started_at<now()-interval '1 minute' then
    update private.terminal_token_attempt_windows set window_started_at=now(),attempts=1,blocked_until=null where terminal_id=p_terminal_id;
    return true;
  end if;
  if v.attempts>=5 then
    update private.terminal_token_attempt_windows set blocked_until=now()+interval '1 minute' where terminal_id=p_terminal_id;
    return false;
  end if;
  update private.terminal_token_attempt_windows set attempts=attempts+1 where terminal_id=p_terminal_id;
  return true;
end $$;
revoke all on function private.allow_terminal_token_attempt(text) from public,anon,authenticated,service_role;

create or replace function private.authenticate_device(p_device_id text,p_secret text)
returns boolean language sql security definer set search_path = '' as $$
  select p_secret is not null and length(p_secret)>=40 and exists(
    select 1 from private.device_credentials c where c.device_id=p_device_id and c.revoked_at is null
      and c.secret_digest=extensions.digest(convert_to(p_secret,'UTF8'),'sha256')
  );
$$;
revoke all on function private.authenticate_device(text,text) from public,anon,authenticated,service_role;

create or replace function public.provision_device(p_device_id text default 'esp8266-main')
returns table(device_id text,device_secret text)
language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if p_device_id<>'esp8266-main' then raise exception 'unsupported device identifier' using errcode='22023'; end if;
  v_secret:=encode(extensions.gen_random_bytes(32),'hex');
  insert into public.device_state(device_id,connected,state) values(p_device_id,false,'{"mode":"physical","provisioned":true}'::jsonb)
    on conflict on constraint device_state_pkey do update set connected=false,updated_at=now();
  insert into private.device_credentials(device_id,secret_digest,revoked_at) values(p_device_id,extensions.digest(convert_to(v_secret,'UTF8'),'sha256'),null)
    on conflict on constraint device_credentials_pkey do update set secret_digest=excluded.secret_digest,revoked_at=null,created_at=now();
  return query select p_device_id,v_secret;
end $$;
revoke all on function public.provision_device(text) from public,anon,authenticated,service_role;
grant execute on function public.provision_device(text) to authenticated;

create or replace function public.heartbeat_device(p_device_id text,p_device_secret text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not private.authenticate_device(p_device_id,p_device_secret) then return false; end if;
  update public.device_state set connected=true,last_heartbeat=now(),updated_at=now() where device_id=p_device_id;
  return found;
end $$;
revoke all on function public.heartbeat_device(text,text) from public,anon,authenticated,service_role;
grant execute on function public.heartbeat_device(text,text) to anon,authenticated;

create or replace function public.claim_device_commands(p_device_id text,p_device_secret text)
returns table(command_id uuid,operation_id uuid,command_type text,payload jsonb,expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.authenticate_device(p_device_id,p_device_secret) then return; end if;
  update public.device_state set connected=true,last_heartbeat=now(),updated_at=now() where device_id=p_device_id;
  return query
  with picked as (
    select c.id from public.hardware_commands c where c.device_id=p_device_id and c.status='pending' and c.expires_at>now()
    order by c.issued_at for update skip locked limit 10
  ), claimed as (
    update public.hardware_commands c set status='received',acknowledged_at=now()
    where c.id in (select picked.id from picked) returning c.id,c.operation_id,c.command_type,c.payload,c.expires_at
  ) select claimed.id,claimed.operation_id,claimed.command_type,claimed.payload,claimed.expires_at from claimed;
end $$;
revoke all on function public.claim_device_commands(text,text) from public,anon,authenticated,service_role;
grant execute on function public.claim_device_commands(text,text) to anon,authenticated;

create or replace function public.ack_device_command(p_device_id text,p_device_secret text,p_command_id uuid,p_status text,p_result jsonb default '{}'::jsonb)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not private.authenticate_device(p_device_id,p_device_secret) or p_status not in ('running','confirmed','failed') then return false; end if;
  update public.hardware_commands set status=p_status,acknowledged_at=now(),result=coalesce(p_result,'{}'::jsonb)
  where id=p_command_id and device_id=p_device_id and status in ('received','running') and expires_at>now();
  return found;
end $$;
revoke all on function public.ack_device_command(text,text,uuid,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.ack_device_command(text,text,uuid,text,jsonb) to anon,authenticated;

create or replace function public.provision_terminal(p_terminal_id text, p_lane text)
returns table(terminal_id text, terminal_secret text)
language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if p_lane not in ('entry','exit') then raise exception 'invalid terminal lane' using errcode='22023'; end if;
  v_secret := encode(extensions.gen_random_bytes(32),'hex');
  insert into public.terminals(terminal_id,lane,enabled,revoked_at) values(p_terminal_id,p_lane,true,null)
    on conflict on constraint terminals_pkey do update set lane=excluded.lane,enabled=true,revoked_at=null;
  insert into private.terminal_credentials(terminal_id,secret_digest,expires_at)
    values(p_terminal_id,extensions.digest(convert_to(v_secret,'UTF8'),'sha256'),null)
    on conflict on constraint terminal_credentials_pkey do update set secret_digest=excluded.secret_digest,expires_at=null,created_at=now();
  delete from private.terminal_attempt_windows as attempts where attempts.terminal_id=p_terminal_id;
  delete from private.terminal_token_attempt_windows as token_attempts where token_attempts.terminal_id=p_terminal_id;
  return query select p_terminal_id,v_secret;
end $$;
revoke all on function public.provision_terminal(text,text) from public,anon,authenticated,service_role;
grant execute on function public.provision_terminal(text,text) to authenticated;

create or replace function public.revoke_terminal(p_terminal_id text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  update public.terminals set enabled=false,revoked_at=now() where terminal_id=p_terminal_id;
  delete from private.terminal_credentials where terminal_id=p_terminal_id;
  delete from private.terminal_attempt_windows where terminal_id=p_terminal_id;
  delete from private.terminal_token_attempt_windows where terminal_id=p_terminal_id;
end $$;
revoke all on function public.revoke_terminal(text) from public,anon,authenticated,service_role;
grant execute on function public.revoke_terminal(text) to authenticated;

create or replace function public.is_current_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and private.is_admin();
$$;
revoke all on function public.is_current_admin() from public,anon,authenticated,service_role;
grant execute on function public.is_current_admin() to authenticated;

create or replace function public.create_reservation(p_reserved_for date)
returns table (reservation_id uuid, access_token text, reserved_for date)
language plpgsql security definer set search_path = '' as $$
declare v_token text; v_token_hmac bytea; v_id uuid; v_count integer; v_random bytea; v_value bigint; v_attempt integer:=0; v_sim boolean;
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if p_reserved_for < (now() at time zone 'America/Argentina/Cordoba')::date then raise exception 'reservation date must be today or later' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_reserved_for::text,0));
  select simulation_mode into v_sim from public.parking_state where id=1 for update;
  if not v_sim or not exists(select 1 from public.device_state where device_id='simulated-esp8266' and connected) then
    raise exception 'reservation synchronization unavailable' using errcode='55000';
  end if;
  select count(*) into v_count from public.reservations r where r.reserved_for=p_reserved_for and r.state not in ('finished','revoked','expired');
  if v_count>=3 then raise exception 'daily reservation capacity reached' using errcode='23514'; end if;
  loop
    v_random:=extensions.gen_random_bytes(4);
    v_value:=get_byte(v_random,0)::bigint*16777216+get_byte(v_random,1)::bigint*65536+get_byte(v_random,2)::bigint*256+get_byte(v_random,3)::bigint;
    if v_value>=4294000000 then continue; end if;
    v_token:=lpad((v_value%1000000)::text,6,'0'); v_token_hmac:=private.reservation_token_hmac(v_token); v_id:=gen_random_uuid(); v_attempt:=v_attempt+1;
    begin
      insert into public.reservations(id,token_suffix,reserved_for,state,created_by,sync_status,version,synced_at)
      values(v_id,right(v_token,3),p_reserved_for,case when p_reserved_for=(now() at time zone 'America/Argentina/Cordoba')::date then 'available' else 'scheduled' end,auth.uid(),case when v_sim then 'confirmed' else 'pending' end,1,case when v_sim then now() else null end);
      insert into private.reservation_token_fingerprints(reservation_id,token_hmac) values(v_id,v_token_hmac);
      exit;
    exception when unique_violation then if v_attempt>=25 then raise exception 'unable to allocate unique reservation token'; end if;
    end;
  end loop;
  insert into public.audit_events(event_type,reservation_id,source,result,actor_id,details)
  values('reservation_created',v_id,'admin','success',auth.uid(),jsonb_build_object('sync_status',case when v_sim then 'confirmed' else 'pending' end));
  return query select v_id,v_token,p_reserved_for;
end $$;
revoke all on function public.create_reservation(date) from public,anon,authenticated,service_role;
grant execute on function public.create_reservation(date) to authenticated;

create or replace function public.revoke_reservation(p_reservation_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_res public.reservations%rowtype;
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  select * into v_res from public.reservations where id=p_reservation_id for update;
  if not found or v_res.state in ('finished','revoked','expired') then return; end if;
  if v_res.vehicle_present then raise exception 'cannot revoke a reservation while its vehicle is present' using errcode='55000'; end if;
  if not exists(select 1 from public.parking_state where id=1 and simulation_mode)
    or not exists(select 1 from public.device_state where device_id='simulated-esp8266' and connected) then
    raise exception 'reservation synchronization unavailable' using errcode='55000';
  end if;
  update public.reservations set state='revoked',sync_status='confirmed',version=version+1,synced_at=now(),updated_at=now() where id=p_reservation_id;
  insert into public.audit_events(event_type,reservation_id,source,result,actor_id) values('reservation_revoked',p_reservation_id,'admin','success',auth.uid());
end $$;
revoke all on function public.revoke_reservation(uuid) from public,anon,authenticated,service_role;
grant execute on function public.revoke_reservation(uuid) to authenticated;

create or replace function private.begin_operation(p_direction text,p_vehicle text,p_reservation_id uuid,p_action text,p_idempotency uuid,p_source text,p_terminal_id text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_op uuid; v_date date:=(now() at time zone 'America/Argentina/Cordoba')::date; v_r public.reservations%rowtype; v_state public.parking_state%rowtype; v_pending integer;
begin
  if p_direction not in ('entry','exit') or p_vehicle not in ('regular','reserved','temporary') or p_source not in ('simulation','terminal') then raise exception 'invalid operation' using errcode='22023'; end if;
  if (p_vehicle='reserved') <> (p_reservation_id is not null) then raise exception 'reservation required for reserved vehicle' using errcode='22023'; end if;
  select * into v_state from public.parking_state where id=1 for update;
  if p_source='simulation' and not v_state.simulation_mode then raise exception 'simulation disabled' using errcode='55000'; end if;
  if p_source='simulation' and not exists(select 1 from public.device_state where device_id='simulated-esp8266' and connected) then raise exception 'simulated device disconnected' using errcode='55000'; end if;
  if exists(select 1 from public.vehicle_operations where idempotency_key=p_idempotency) then
    if exists(select 1 from public.vehicle_operations where idempotency_key=p_idempotency and direction=p_direction and vehicle_type=p_vehicle and reservation_id is not distinct from p_reservation_id and reservation_action is not distinct from p_action and source=p_source and terminal_id is not distinct from p_terminal_id) then
      select id into v_op from public.vehicle_operations where idempotency_key=p_idempotency;
      return v_op;
    end if;
    raise exception 'idempotency key already used for another operation' using errcode='23505';
  end if;
  if exists(select 1 from public.vehicle_operations where direction=p_direction and status in ('pending','detected')) then raise exception 'lane operation in progress' using errcode='55000'; end if;
  select count(*) into v_pending from public.vehicle_operations where vehicle_type=p_vehicle and direction=p_direction and status in ('pending','detected');
  if p_direction='entry' then
    if p_vehicle='regular' and v_state.regular_count+v_state.reserved_contingency_count+v_pending>=7 then raise exception 'regular capacity reached' using errcode='23514'; end if;
    if p_vehicle='temporary' then null; end if;
    if p_vehicle='reserved' then
      select * into v_r from public.reservations where id=p_reservation_id for update;
      if not found or v_r.sync_status<>'confirmed' or v_r.reserved_for<>v_date or v_r.state not in ('available','scheduled','retained') or v_r.vehicle_present then raise exception 'reservation unavailable' using errcode='42501'; end if;
      if v_state.reserved_count+v_pending>=3 then raise exception 'reserved capacity reached' using errcode='23514'; end if;
    end if;
  else
    if p_vehicle='regular' and v_state.regular_count<=0 then raise exception 'no regular vehicle inside' using errcode='23514'; end if;
    if p_vehicle='temporary' and v_state.temporary_count<=0 then raise exception 'no temporary vehicle inside' using errcode='23514'; end if;
    if p_vehicle='reserved' then
      select * into v_r from public.reservations where id=p_reservation_id for update;
      if not found or v_r.sync_status<>'confirmed' or not v_r.vehicle_present or v_r.state not in ('parked','expired_occupied') then raise exception 'reserved vehicle not present' using errcode='42501'; end if;
      if p_action not in ('retain','finish') then raise exception 'invalid reservation action' using errcode='22023'; end if;
    end if;
  end if;
  insert into public.vehicle_operations(direction,vehicle_type,reservation_id,status,source,reservation_action,idempotency_key,terminal_id)
    values(p_direction,p_vehicle,p_reservation_id,'pending',p_source,p_action,p_idempotency,p_terminal_id) returning id into v_op;
  update public.parking_state set entry_gate=case when p_direction='entry' then 'opening' else entry_gate end,
    exit_gate=case when p_direction='exit' then 'opening' else exit_gate end,
    state_version=state_version+1,updated_at=now() where id=1;
  return v_op;
end $$;
revoke all on function private.begin_operation(text,text,uuid,text,uuid,text,text) from public,anon,authenticated,service_role;

create or replace function public.start_simulated_operation(p_direction text,p_vehicle text,p_reservation_token text default null,p_action text default 'retain',p_idempotency_key uuid default gen_random_uuid())
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_res uuid; v_hmac bytea;
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if p_vehicle='reserved' then
    v_hmac:=private.reservation_token_hmac(p_reservation_token);
    select f.reservation_id into v_res from private.reservation_token_fingerprints f where f.token_hmac=v_hmac;
    if v_res is null then raise exception 'reservation unavailable' using errcode='42501'; end if;
  end if;
  return private.begin_operation(p_direction,p_vehicle,v_res,p_action,p_idempotency_key,'simulation',null);
end $$;
revoke all on function public.start_simulated_operation(text,text,text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.start_simulated_operation(text,text,text,text,uuid) to authenticated;

create or replace function public.inspect_terminal_reservation(p_terminal_id text,p_terminal_secret text,p_token text)
returns table(reservation_id uuid,reserved_for date,reservation_state text,vehicle_present boolean,can_retain boolean)
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_lane text; v_r public.reservations%rowtype; v_hmac bytea;
begin
  select lane into v_lane from public.terminals where terminal_id=p_terminal_id and enabled and revoked_at is null;
  if v_lane is null or not private.authenticate_terminal(p_terminal_id,p_terminal_secret,v_lane) or p_token !~ '^[0-9]{6}$' then return; end if;
  if not private.allow_terminal_token_attempt(p_terminal_id) then return; end if;
  v_hmac:=private.reservation_token_hmac(p_token);
  select f.reservation_id into v_id from private.reservation_token_fingerprints f where f.token_hmac=v_hmac;
  select * into v_r from public.reservations r where r.id=v_id;
  if not found or v_r.sync_status<>'confirmed' then return; end if;
  if v_lane='entry' and (v_r.reserved_for<>(now() at time zone 'America/Argentina/Cordoba')::date or v_r.state not in ('available','scheduled','retained') or v_r.vehicle_present) then return; end if;
  if v_lane='exit' and (not v_r.vehicle_present or v_r.state not in ('parked','expired_occupied')) then return; end if;
  return query select v_r.id,v_r.reserved_for,v_r.state,v_r.vehicle_present,(v_r.reserved_for=(now() at time zone 'America/Argentina/Cordoba')::date and v_r.vehicle_present);
end $$;
revoke all on function public.inspect_terminal_reservation(text,text,text) from public,anon,authenticated,service_role;
grant execute on function public.inspect_terminal_reservation(text,text,text) to anon,authenticated;

create or replace function public.start_terminal_operation(p_terminal_id text,p_terminal_secret text,p_direction text,p_vehicle text,p_reservation_token text default null,p_action text default 'finish',p_idempotency_key uuid default gen_random_uuid())
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_res uuid; v_hmac bytea; v_op uuid;
begin
  if not private.authenticate_terminal(p_terminal_id,p_terminal_secret,p_direction) then return null; end if;
  if not exists(select 1 from public.device_state where device_id='esp8266-main' and connected and last_heartbeat>now()-interval '30 seconds') then return null; end if;
  if p_vehicle='reserved' then
    if not private.allow_terminal_token_attempt(p_terminal_id) then return null; end if;
    if p_reservation_token !~ '^[0-9]{6}$' then return null; end if;
    v_hmac:=private.reservation_token_hmac(p_reservation_token);
    select f.reservation_id into v_res from private.reservation_token_fingerprints f where f.token_hmac=v_hmac;
    if v_res is null then return null; end if;
    begin
      v_op:=private.begin_operation(p_direction,p_vehicle,v_res,p_action,p_idempotency_key,'terminal',p_terminal_id);
      insert into public.hardware_commands(device_id,operation_id,command_type,payload,expires_at)
        values('esp8266-main',v_op,'open_gate',jsonb_build_object('direction',p_direction),now()+interval '15 seconds') on conflict do nothing;
      return v_op;
    exception when others then return null;
    end;
  end if;
  begin
    v_op:=private.begin_operation(p_direction,p_vehicle,v_res,p_action,p_idempotency_key,'terminal',p_terminal_id);
    insert into public.hardware_commands(device_id,operation_id,command_type,payload,expires_at)
      values('esp8266-main',v_op,'open_gate',jsonb_build_object('direction',p_direction),now()+interval '15 seconds') on conflict do nothing;
    return v_op;
  exception when others then return null;
  end;
end $$;
revoke all on function public.start_terminal_operation(text,text,text,text,text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.start_terminal_operation(text,text,text,text,text,text,uuid) to anon,authenticated;

create or replace function public.get_terminal_operation(p_terminal_id text,p_terminal_secret text,p_operation_id uuid)
returns table(operation_id uuid,direction text,vehicle_type text,status text)
language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype;
begin
  select * into v_op from public.vehicle_operations where id=p_operation_id;
  if not found or v_op.source<>'terminal' or v_op.terminal_id<>p_terminal_id or not private.authenticate_terminal(p_terminal_id,p_terminal_secret,v_op.direction) then return; end if;
  return query select v_op.id,v_op.direction,v_op.vehicle_type,v_op.status;
end $$;
revoke all on function public.get_terminal_operation(text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.get_terminal_operation(text,text,uuid) to anon,authenticated;

create or replace function public.get_active_terminal_operation(p_terminal_id text,p_terminal_secret text)
returns table(operation_id uuid,status text)
language plpgsql security definer set search_path = '' as $$
declare v_lane text;
begin
  select lane into v_lane from public.terminals where terminal_id=p_terminal_id and enabled and revoked_at is null;
  if v_lane is null or not private.authenticate_terminal(p_terminal_id,p_terminal_secret,v_lane) then return; end if;
  return query select o.id,o.status from public.vehicle_operations o where o.terminal_id=p_terminal_id and o.status in ('pending','detected') order by o.created_at desc limit 1;
end $$;
revoke all on function public.get_active_terminal_operation(text,text) from public,anon,authenticated,service_role;
grant execute on function public.get_active_terminal_operation(text,text) to anon,authenticated;

create or replace function private.set_operation_sensor(p_operation_id uuid,p_detected boolean,p_clear_ms integer)
returns void language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype;
begin
  select * into v_op from public.vehicle_operations where id=p_operation_id for update;
  if not found or v_op.status not in ('pending','detected') then raise exception 'operation unavailable' using errcode='55000'; end if;
  if p_detected then
    update public.vehicle_operations set status='detected',sensor_detected_at=now(),sensor_released_at=null,sensor_clear_ms=null where id=p_operation_id;
    update public.parking_state set entry_sensor=case when v_op.direction='entry' then true else entry_sensor end,exit_sensor=case when v_op.direction='exit' then true else exit_sensor end,
      entry_gate=case when v_op.direction='entry' then 'detected' else entry_gate end,exit_gate=case when v_op.direction='exit' then 'detected' else exit_gate end,state_version=state_version+1,updated_at=now() where id=1;
  else
    if v_op.status<>'detected' or p_clear_ms<500 then raise exception 'stable sensor release required' using errcode='55000'; end if;
    update public.vehicle_operations set sensor_released_at=now(),sensor_clear_ms=p_clear_ms where id=p_operation_id;
    update public.parking_state set entry_sensor=case when v_op.direction='entry' then false else entry_sensor end,exit_sensor=case when v_op.direction='exit' then false else exit_sensor end,state_version=state_version+1,updated_at=now() where id=1;
  end if;
end $$;
revoke all on function private.set_operation_sensor(uuid,boolean,integer) from public,anon,authenticated,service_role;

create or replace function public.simulate_sensor(p_operation_id uuid,p_detected boolean,p_clear_ms integer default 500)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if not exists(select 1 from public.vehicle_operations where id=p_operation_id and source='simulation') then raise exception 'simulation operation required' using errcode='42501'; end if;
  perform private.set_operation_sensor(p_operation_id,p_detected,p_clear_ms);
end $$;
revoke all on function public.simulate_sensor(uuid,boolean,integer) from public,anon,authenticated,service_role;
grant execute on function public.simulate_sensor(uuid,boolean,integer) to authenticated;

create or replace function public.complete_operation(p_operation_id uuid,p_terminal_id text default null,p_terminal_secret text default null,p_clear_ms integer default 500)
returns void language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype; v_state public.parking_state%rowtype; v_new_state text;
begin
  select * into v_op from public.vehicle_operations where id=p_operation_id for update;
  if not found then raise exception 'operation unavailable' using errcode='55000'; end if;
  if v_op.status='confirmed' then return; end if;
  if v_op.source='simulation' then
    if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  elsif not private.authenticate_terminal(p_terminal_id,p_terminal_secret,v_op.direction) or v_op.terminal_id<>p_terminal_id then
    return;
  end if;
  if v_op.status<>'detected' or v_op.sensor_released_at is null or p_clear_ms<500 or v_op.sensor_released_at>now()-interval '500 milliseconds' then raise exception 'stable sensor release required' using errcode='55000'; end if;
  select * into v_state from public.parking_state where id=1 for update;
  if v_op.vehicle_type='regular' then
    update public.parking_state set regular_count=regular_count+case when v_op.direction='entry' then 1 else -1 end where id=1;
  elsif v_op.vehicle_type='reserved' then
    if v_op.direction='entry' then
      update public.reservations set state='parked',vehicle_present=true,updated_at=now(),version=version+1 where id=v_op.reservation_id;
      update public.parking_state set reserved_count=reserved_count+1 where id=1;
    else
      v_new_state:=case when v_state.simulation_mode and (select reserved_for from public.reservations where id=v_op.reservation_id)=(now() at time zone 'America/Argentina/Cordoba')::date and v_op.reservation_action='retain' then 'retained' else 'finished' end;
      update public.reservations set state=v_new_state,vehicle_present=false,updated_at=now(),version=version+1 where id=v_op.reservation_id;
      update public.parking_state set reserved_count=reserved_count-1 where id=1;
    end if;
  else
    update public.parking_state set temporary_count=temporary_count+case when v_op.direction='entry' then 1 else -1 end where id=1;
  end if;
  update public.vehicle_operations set status='confirmed',confirmed_at=now() where id=p_operation_id;
  update public.parking_state set entry_gate=case when v_op.direction='entry' then 'closed' else entry_gate end,exit_gate=case when v_op.direction='exit' then 'closed' else exit_gate end,state_version=state_version+1,updated_at=now() where id=1;
  insert into public.audit_events(event_type,vehicle_type,operation_id,reservation_id,source,result,actor_id,details)
  values(case when v_op.direction='entry' then 'vehicle_entered' else 'vehicle_exited' end,v_op.vehicle_type,p_operation_id,v_op.reservation_id,v_op.source,'success',auth.uid(),jsonb_build_object('sensor_clear_ms',p_clear_ms,'terminal_id',v_op.terminal_id));
end $$;
revoke all on function public.complete_operation(uuid,text,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.complete_operation(uuid,text,text,integer) to anon,authenticated;

create or replace function public.report_device_sensor(p_device_id text,p_device_secret text,p_operation_id uuid,p_detected boolean,p_clear_ms integer default 500)
returns void language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype;
begin
  select * into v_op from public.vehicle_operations where id=p_operation_id for update;
  if not found or v_op.source<>'terminal' or not private.authenticate_device(p_device_id,p_device_secret)
    or not exists(select 1 from public.hardware_commands c where c.operation_id=p_operation_id and c.command_type='open_gate' and c.status='confirmed') then
    return;
  end if;
  update public.device_state set connected=true,last_heartbeat=now(),updated_at=now() where device_id=p_device_id;
  perform private.set_operation_sensor(p_operation_id,p_detected,p_clear_ms);
end $$;
revoke all on function public.report_device_sensor(text,text,uuid,boolean,integer) from public,anon,authenticated,service_role;
grant execute on function public.report_device_sensor(text,text,uuid,boolean,integer) to anon,authenticated;

create or replace function public.finish_simulated_operation(p_operation_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  perform public.complete_operation(p_operation_id,null,null,500);
end $$;
revoke all on function public.finish_simulated_operation(uuid) from public,anon,authenticated,service_role;
grant execute on function public.finish_simulated_operation(uuid) to authenticated;

create or replace function public.cancel_operation(p_operation_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype;
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  select * into v_op from public.vehicle_operations where id=p_operation_id for update;
  if not found or v_op.status not in ('pending','detected') then return; end if;
  update public.vehicle_operations set status='cancelled' where id=p_operation_id;
  update public.hardware_commands set status='cancelled' where operation_id=p_operation_id and status in ('pending','received');
  update public.parking_state set entry_gate=case when v_op.direction='entry' then 'closed' else entry_gate end,exit_gate=case when v_op.direction='exit' then 'closed' else exit_gate end,
    entry_sensor=case when v_op.direction='entry' then false else entry_sensor end,exit_sensor=case when v_op.direction='exit' then false else exit_sensor end,state_version=state_version+1,updated_at=now() where id=1;
  insert into public.audit_events(event_type,operation_id,source,result,actor_id) values('operation_cancelled',p_operation_id,v_op.source,'cancelled',auth.uid());
end $$;
revoke all on function public.cancel_operation(uuid) from public,anon,authenticated,service_role;
grant execute on function public.cancel_operation(uuid) to authenticated;

create or replace function public.set_simulation_settings(p_simulation_mode boolean,p_automatic boolean,p_night boolean,p_device_connected boolean default true)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if exists(select 1 from public.vehicle_operations where status in ('pending','detected')) then raise exception 'cannot change mode during an operation' using errcode='55000'; end if;
  update public.parking_state set simulation_mode=p_simulation_mode,automatic_simulation=p_automatic,night_mode=p_night,state_version=state_version+1,updated_at=now() where id=1;
  update public.device_state set connected=p_device_connected,state=jsonb_build_object('mode',case when p_simulation_mode then 'simulation' else 'offline' end),updated_at=now() where device_id='simulated-esp8266';
  insert into public.audit_events(event_type,source,result,actor_id,details) values('simulation_settings_changed','admin','success',auth.uid(),jsonb_build_object('simulation_mode',p_simulation_mode,'automatic',p_automatic,'night',p_night,'device_connected',p_device_connected));
end $$;
revoke all on function public.set_simulation_settings(boolean,boolean,boolean,boolean) from public,anon,authenticated,service_role;
grant execute on function public.set_simulation_settings(boolean,boolean,boolean,boolean) to authenticated;

create or replace function public.reset_parking_demo()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if exists(select 1 from public.vehicle_operations where status in ('pending','detected')) then raise exception 'cancel active operations before reset' using errcode='55000'; end if;
  update public.parking_state set regular_count=0,reserved_count=0,temporary_count=0,reserved_contingency_count=0,entry_gate='closed',exit_gate='closed',entry_sensor=false,exit_sensor=false,night_mode=false,state_version=state_version+1,updated_at=now() where id=1;
  update public.reservations set state='revoked',vehicle_present=false,updated_at=now(),version=version+1 where state not in ('finished','revoked');
  insert into public.audit_events(event_type,source,result,actor_id) values('parking_reset','admin','success',auth.uid());
end $$;
revoke all on function public.reset_parking_demo() from public,anon,authenticated,service_role;
grant execute on function public.reset_parking_demo() to authenticated;

-- La vista administrativa no incluye HMAC, sólo metadatos y el sufijo ya previsto.
create or replace view public.reservation_admin_view with (security_invoker=true) as
select r.id,r.token_suffix,r.reserved_for,
  case when r.vehicle_present and r.reserved_for<(now() at time zone 'America/Argentina/Cordoba')::date then 'expired_occupied'
       when not r.vehicle_present and r.reserved_for<(now() at time zone 'America/Argentina/Cordoba')::date and r.state not in ('finished','revoked') then 'expired'
       else r.state end as effective_state,
  r.vehicle_present,r.created_at,r.updated_at,r.sync_status,r.version,r.synced_at
from public.reservations r;
grant select on public.reservation_admin_view to authenticated;

-- No se otorga escritura directa a tablas desde la Data API.
revoke all on table public.terminals from public,anon,authenticated,service_role;
grant select,insert,update,delete on table public.terminals to authenticated;
revoke all on table public.vehicle_operations,public.audit_events,public.device_state,public.hardware_commands,public.reservations from anon;

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='parking_state') then alter publication supabase_realtime add table public.parking_state; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='reservations') then alter publication supabase_realtime add table public.reservations; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='vehicle_operations') then alter publication supabase_realtime add table public.vehicle_operations; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='audit_events') then alter publication supabase_realtime add table public.audit_events; end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='device_state') then alter publication supabase_realtime add table public.device_state; end if;
end $$;

