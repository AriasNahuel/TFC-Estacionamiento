-- Controlador simulado para completar operaciones iniciadas desde terminales.
-- `source` identifica al controlador; `request_origin` identifica quién pidió
-- el movimiento. Así el simulador y el ESP físico usan las mismas reglas.
alter table public.vehicle_operations
  add column if not exists request_origin text not null default 'admin'
    check (request_origin in ('terminal','admin'));

create or replace function private.begin_operation(
  p_direction text, p_vehicle text, p_reservation_id uuid, p_action text,
  p_idempotency uuid, p_source text, p_terminal_id text
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_op uuid;
  v_date date := (now() at time zone 'America/Argentina/Cordoba')::date;
  v_r public.reservations%rowtype;
  v_state public.parking_state%rowtype;
  v_pending integer;
begin
  if p_direction not in ('entry','exit') or p_vehicle not in ('regular','reserved','temporary')
     or p_source not in ('simulation','device') then
    raise exception 'invalid operation' using errcode='22023';
  end if;
  if (p_vehicle='reserved') <> (p_reservation_id is not null) then
    raise exception 'reservation required for reserved vehicle' using errcode='22023';
  end if;

  select * into v_state from public.parking_state where id=1 for update;
  if p_source='simulation' and (not v_state.simulation_mode or not exists (
    select 1 from public.device_state d where d.device_id='simulated-esp8266' and d.connected
  )) then raise exception 'simulated controller unavailable' using errcode='55000'; end if;
  if p_source='device' and (v_state.simulation_mode or not exists (
    select 1 from public.device_state d where d.device_id='esp8266-main' and d.connected
      and d.last_heartbeat>now()-interval '30 seconds'
  )) then raise exception 'physical controller unavailable' using errcode='55000'; end if;

  if exists(select 1 from public.vehicle_operations o where o.idempotency_key=p_idempotency) then
    select o.id into v_op from public.vehicle_operations o
    where o.idempotency_key=p_idempotency and o.direction=p_direction and o.vehicle_type=p_vehicle
      and o.reservation_id is not distinct from p_reservation_id
      and o.reservation_action is not distinct from p_action and o.source=p_source
      and o.terminal_id is not distinct from p_terminal_id;
    if v_op is not null then return v_op; end if;
    raise exception 'idempotency key already used for another operation' using errcode='23505';
  end if;
  if exists(select 1 from public.vehicle_operations o where o.direction=p_direction and o.status in ('pending','detected')) then
    raise exception 'lane operation in progress' using errcode='55000';
  end if;
  select count(*) into v_pending from public.vehicle_operations o
    where o.vehicle_type=p_vehicle and o.direction=p_direction and o.status in ('pending','detected');

  if p_direction='entry' then
    if p_vehicle='regular' and v_state.regular_count+v_state.reserved_contingency_count+v_pending>=v_state.regular_capacity then
      raise exception 'regular capacity reached' using errcode='23514';
    end if;
    if p_vehicle='reserved' then
      select * into v_r from public.reservations r where r.id=p_reservation_id for update;
      if not found or v_r.sync_status<>'confirmed' or v_r.reserved_for<>v_date
         or v_r.state not in ('available','scheduled','retained') or v_r.vehicle_present then
        raise exception 'reservation unavailable' using errcode='42501';
      end if;
      if v_state.reserved_count+v_pending>=v_state.reserved_capacity then raise exception 'reserved capacity reached' using errcode='23514'; end if;
    end if;
  else
    if p_vehicle='regular' and v_state.regular_count<=0 then raise exception 'no regular vehicle inside' using errcode='23514'; end if;
    if p_vehicle='temporary' and v_state.temporary_count<=0 then raise exception 'no temporary vehicle inside' using errcode='23514'; end if;
    if p_vehicle='reserved' then
      select * into v_r from public.reservations r where r.id=p_reservation_id for update;
      if not found or v_r.sync_status<>'confirmed' or not v_r.vehicle_present
         or v_r.state not in ('parked','expired_occupied') then raise exception 'reserved vehicle not present' using errcode='42501'; end if;
      if p_action not in ('retain','finish') then raise exception 'invalid reservation action' using errcode='22023'; end if;
    end if;
  end if;

  insert into public.vehicle_operations(direction,vehicle_type,reservation_id,status,source,reservation_action,idempotency_key,terminal_id,request_origin)
  values(p_direction,p_vehicle,p_reservation_id,'pending',p_source,p_action,p_idempotency,p_terminal_id,
    case when p_terminal_id is null then 'admin' else 'terminal' end) returning id into v_op;
  update public.parking_state set entry_gate=case when p_direction='entry' then 'opening' else entry_gate end,
    exit_gate=case when p_direction='exit' then 'opening' else exit_gate end,
    state_version=state_version+1,updated_at=now() where id=1;
  return v_op;
end $$;
revoke all on function private.begin_operation(text,text,uuid,text,uuid,text,text) from public,anon,authenticated,service_role;

create or replace function public.start_terminal_operation(
  p_terminal_id text,p_terminal_secret text,p_direction text,p_vehicle text,
  p_reservation_token text default null,p_action text default 'finish',p_idempotency_key uuid default gen_random_uuid()
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_res uuid; v_hmac bytea; v_op uuid; v_source text; v_mode boolean;
begin
  if not private.authenticate_terminal(p_terminal_id,p_terminal_secret,p_direction) then return null; end if;
  select ps.simulation_mode into v_mode from public.parking_state ps where ps.id=1;
  if not found then return null; end if;
  if v_mode then
    if not exists(select 1 from public.device_state d where d.device_id='simulated-esp8266' and d.connected) then return null; end if;
    v_source:='simulation';
  else
    if not exists(select 1 from public.device_state d where d.device_id='esp8266-main' and d.connected and d.last_heartbeat>now()-interval '30 seconds') then return null; end if;
    v_source:='device';
  end if;
  if p_vehicle='reserved' then
    if not private.allow_terminal_token_attempt(p_terminal_id) or p_reservation_token !~ '^[0-9]{6}$' then return null; end if;
    v_hmac:=private.reservation_token_hmac(p_reservation_token);
    select f.reservation_id into v_res from private.reservation_token_fingerprints f where f.token_hmac=v_hmac;
    if v_res is null then return null; end if;
  end if;
  begin
    v_op:=private.begin_operation(p_direction,p_vehicle,v_res,p_action,p_idempotency_key,v_source,p_terminal_id);
    if v_source='device' then
      insert into public.hardware_commands(device_id,operation_id,command_type,payload,expires_at)
      values('esp8266-main',v_op,'open_gate',jsonb_build_object('direction',p_direction),now()+interval '15 seconds') on conflict do nothing;
    end if;
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
  select * into v_op from public.vehicle_operations o where o.id=p_operation_id;
  if not found or v_op.request_origin<>'terminal' or v_op.terminal_id<>p_terminal_id
    or not private.authenticate_terminal(p_terminal_id,p_terminal_secret,v_op.direction) then return; end if;
  return query select v_op.id,v_op.direction,v_op.vehicle_type,v_op.status;
end $$;
revoke all on function public.get_terminal_operation(text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.get_terminal_operation(text,text,uuid) to anon,authenticated;

create or replace function private.set_operation_sensor(p_operation_id uuid,p_detected boolean,p_clear_ms integer)
returns void language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype; v_event_at timestamptz:=clock_timestamp();
begin
  select * into v_op from public.vehicle_operations o where o.id=p_operation_id for update;
  if not found or v_op.status not in ('pending','detected') then raise exception 'operation unavailable' using errcode='55000'; end if;
  if p_detected then
    update public.vehicle_operations set status='detected',sensor_detected_at=v_event_at,sensor_released_at=null,sensor_clear_ms=null where id=p_operation_id;
    update public.parking_state set entry_sensor=case when v_op.direction='entry' then true else entry_sensor end,
      exit_sensor=case when v_op.direction='exit' then true else exit_sensor end,
      entry_gate=case when v_op.direction='entry' then 'detected' else entry_gate end,
      exit_gate=case when v_op.direction='exit' then 'detected' else exit_gate end,
      state_version=state_version+1,updated_at=v_event_at where id=1;
  else
    if v_op.status<>'detected' or p_clear_ms<500 then raise exception 'stable sensor release required' using errcode='55000'; end if;
    update public.vehicle_operations set sensor_released_at=v_event_at,sensor_clear_ms=p_clear_ms where id=p_operation_id;
    update public.parking_state set entry_sensor=case when v_op.direction='entry' then false else entry_sensor end,
      exit_sensor=case when v_op.direction='exit' then false else exit_sensor end,
      state_version=state_version+1,updated_at=v_event_at where id=1;
  end if;
end $$;
revoke all on function private.set_operation_sensor(uuid,boolean,integer) from public,anon,authenticated,service_role;

create or replace function public.simulate_sensor(p_operation_id uuid,p_detected boolean,p_clear_ms integer default 500)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if not exists(select 1 from public.vehicle_operations o where o.id=p_operation_id and o.source='simulation') then
    raise exception 'simulation operation required' using errcode='42501';
  end if;
  if not exists(select 1 from public.parking_state ps where ps.id=1 and ps.simulation_mode)
     or not exists(select 1 from public.device_state d where d.device_id='simulated-esp8266' and d.connected) then
    raise exception 'simulated controller unavailable' using errcode='55000';
  end if;
  perform private.set_operation_sensor(p_operation_id,p_detected,p_clear_ms);
end $$;
revoke all on function public.simulate_sensor(uuid,boolean,integer) from public,anon,authenticated,service_role;
grant execute on function public.simulate_sensor(uuid,boolean,integer) to authenticated;

create or replace function public.complete_operation(p_operation_id uuid,p_terminal_id text default null,p_terminal_secret text default null,p_clear_ms integer default 500)
returns void language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype;
begin
  select * into v_op from public.vehicle_operations o where o.id=p_operation_id for update;
  if not found then raise exception 'operation unavailable' using errcode='55000'; end if;
  if v_op.status='confirmed' then return; end if;
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if p_terminal_id is not null or p_terminal_secret is not null then raise exception 'terminal confirmation is not supported' using errcode='42501'; end if;
  perform private.confirm_controller_operation(p_operation_id,p_clear_ms);
end $$;
revoke all on function public.complete_operation(uuid,text,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.complete_operation(uuid,text,text,integer) to anon,authenticated;

create or replace function private.confirm_controller_operation(p_operation_id uuid,p_clear_ms integer)
returns void language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype; v_state public.parking_state%rowtype; v_new_state text;
begin
  select * into v_op from public.vehicle_operations o where o.id=p_operation_id for update;
  if not found or v_op.status not in ('detected','confirmed') then raise exception 'operation unavailable' using errcode='55000'; end if;
  if v_op.status='confirmed' then return; end if;
  if v_op.sensor_released_at is null or p_clear_ms<500 or v_op.sensor_released_at>clock_timestamp()-interval '500 milliseconds' then
    raise exception 'stable sensor release required' using errcode='55000';
  end if;
  select * into v_state from public.parking_state ps where ps.id=1 for update;
  if v_op.vehicle_type='regular' then
    update public.parking_state set regular_count=regular_count+case when v_op.direction='entry' then 1 else -1 end where id=1;
  elsif v_op.vehicle_type='reserved' then
    if v_op.direction='entry' then
      update public.reservations set state='parked',vehicle_present=true,updated_at=now(),version=version+1 where id=v_op.reservation_id;
      update public.parking_state set reserved_count=reserved_count+1 where id=1;
    else
      v_new_state:=case when v_state.simulation_mode and (select r.reserved_for from public.reservations r where r.id=v_op.reservation_id)=(now() at time zone 'America/Argentina/Cordoba')::date and v_op.reservation_action='retain' then 'retained' else 'finished' end;
      update public.reservations set state=v_new_state,vehicle_present=false,updated_at=now(),version=version+1 where id=v_op.reservation_id;
      update public.parking_state set reserved_count=reserved_count-1 where id=1;
    end if;
  else
    update public.parking_state set temporary_count=temporary_count+case when v_op.direction='entry' then 1 else -1 end where id=1;
  end if;
  update public.vehicle_operations set status='confirmed',confirmed_at=now() where id=p_operation_id and status<>'confirmed';
  update public.parking_state set entry_gate=case when v_op.direction='entry' then 'closed' else entry_gate end,
    exit_gate=case when v_op.direction='exit' then 'closed' else exit_gate end,state_version=state_version+1,updated_at=now() where id=1;
  insert into public.audit_events(event_type,vehicle_type,operation_id,reservation_id,source,result,actor_id,details)
  values(case when v_op.direction='entry' then 'vehicle_entered' else 'vehicle_exited' end,v_op.vehicle_type,p_operation_id,v_op.reservation_id,v_op.source,'success',auth.uid(),
    jsonb_build_object('sensor_clear_ms',p_clear_ms,'terminal_id',v_op.terminal_id,'request_origin',v_op.request_origin,'controller',case when v_op.source='simulation' then 'simulated-esp8266' else 'esp8266-main' end));
end $$;
revoke all on function private.confirm_controller_operation(uuid,integer) from public,anon,authenticated,service_role;

create or replace function public.finish_simulated_operation(p_operation_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if not exists(select 1 from public.vehicle_operations o where o.id=p_operation_id and o.source='simulation') then raise exception 'simulation operation required' using errcode='42501'; end if;
  if not exists(select 1 from public.parking_state ps where ps.id=1 and ps.simulation_mode)
     or not exists(select 1 from public.device_state d where d.device_id='simulated-esp8266' and d.connected) then
    raise exception 'simulated controller unavailable' using errcode='55000';
  end if;
  perform private.confirm_controller_operation(p_operation_id,500);
end $$;
revoke all on function public.finish_simulated_operation(uuid) from public,anon,authenticated,service_role;
grant execute on function public.finish_simulated_operation(uuid) to authenticated;

create or replace function public.finish_device_operation(p_device_id text,p_device_secret text,p_operation_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_device_id<>'esp8266-main' or not private.authenticate_device(p_device_id,p_device_secret) then
    raise exception 'device authentication required' using errcode='42501';
  end if;
  if not exists(select 1 from public.vehicle_operations o where o.id=p_operation_id and o.source='device') then
    raise exception 'physical operation required' using errcode='42501';
  end if;
  perform private.confirm_controller_operation(p_operation_id,500);
end $$;
revoke all on function public.finish_device_operation(text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.finish_device_operation(text,text,uuid) to anon,authenticated;

create or replace function public.report_device_sensor(p_device_id text,p_device_secret text,p_operation_id uuid,p_detected boolean,p_clear_ms integer default 500)
returns void language plpgsql security definer set search_path = '' as $$
declare v_op public.vehicle_operations%rowtype;
begin
  select * into v_op from public.vehicle_operations o where o.id=p_operation_id for update;
  if not found or v_op.source<>'device' or not private.authenticate_device(p_device_id,p_device_secret)
    or p_device_id<>'esp8266-main'
    or not exists(select 1 from public.hardware_commands c where c.operation_id=p_operation_id and c.command_type='open_gate' and c.status='confirmed') then return; end if;
  update public.device_state set connected=true,last_heartbeat=now(),updated_at=now() where device_id=p_device_id;
  perform private.set_operation_sensor(p_operation_id,p_detected,p_clear_ms);
end $$;
revoke all on function public.report_device_sensor(text,text,uuid,boolean,integer) from public,anon,authenticated,service_role;
grant execute on function public.report_device_sensor(text,text,uuid,boolean,integer) to anon,authenticated;

create or replace function public.set_simulation_settings(p_simulation_mode boolean,p_automatic boolean,p_night boolean,p_device_connected boolean default true)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_admin() then raise exception 'administrator role required' using errcode='42501'; end if;
  if exists(select 1 from public.vehicle_operations o where o.status in ('pending','detected')) then
    raise exception 'cancel active operations before changing controller mode' using errcode='55000';
  end if;
  update public.parking_state set simulation_mode=p_simulation_mode,automatic_simulation=p_automatic,night_mode=p_night,state_version=state_version+1,updated_at=now() where id=1;
  update public.device_state set connected=p_device_connected,state=jsonb_build_object('mode',case when p_device_connected then 'simulation' else 'offline' end),updated_at=now() where device_id='simulated-esp8266';
  insert into public.audit_events(event_type,source,result,actor_id,details)
  values('simulation_settings_changed','simulation','success',auth.uid(),jsonb_build_object('simulation_mode',p_simulation_mode,'automatic',p_automatic,'simulator_connected',p_device_connected));
end $$;
revoke all on function public.set_simulation_settings(boolean,boolean,boolean,boolean) from public,anon,authenticated,service_role;
grant execute on function public.set_simulation_settings(boolean,boolean,boolean,boolean) to authenticated;

