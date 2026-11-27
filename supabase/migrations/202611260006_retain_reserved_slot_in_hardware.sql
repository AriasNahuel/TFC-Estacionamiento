-- Conservar una reserva del día debe ocupar su cupo administrativo tanto en
-- simulación como en hardware; el modo solo distingue el controlador físico.
create or replace function private.confirm_controller_operation(p_operation_id uuid,p_clear_ms integer)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_op public.vehicle_operations%rowtype;
  v_state public.parking_state%rowtype;
  v_new_state text;
begin
  select * into v_op from public.vehicle_operations o where o.id=p_operation_id for update;
  if not found or v_op.status not in ('detected','confirmed') then
    raise exception 'operation unavailable' using errcode='55000';
  end if;
  if v_op.status='confirmed' then return; end if;
  if v_op.sensor_released_at is null or p_clear_ms<500
     or v_op.sensor_released_at>clock_timestamp()-interval '500 milliseconds' then
    raise exception 'stable sensor release required' using errcode='55000';
  end if;
  select * into v_state from public.parking_state ps where ps.id=1 for update;
  if v_op.vehicle_type='regular' then
    update public.parking_state
    set regular_count=regular_count+case when v_op.direction='entry' then 1 else -1 end
    where id=1;
  elsif v_op.vehicle_type='reserved' then
    if v_op.direction='entry' then
      update public.reservations
      set state='parked',vehicle_present=true,updated_at=now(),version=version+1
      where id=v_op.reservation_id;
      update public.parking_state set reserved_count=reserved_count+1 where id=1;
    else
      v_new_state := case
        when (select r.reserved_for from public.reservations r where r.id=v_op.reservation_id)
             = (now() at time zone 'America/Argentina/Cordoba')::date
             and v_op.reservation_action='retain'
          then 'retained'
        else 'finished'
      end;
      update public.reservations
      set state=v_new_state,vehicle_present=false,updated_at=now(),version=version+1
      where id=v_op.reservation_id;
      update public.parking_state set reserved_count=reserved_count-1 where id=1;
    end if;
  else
    update public.parking_state
    set temporary_count=temporary_count+case when v_op.direction='entry' then 1 else -1 end
    where id=1;
  end if;
  update public.vehicle_operations set status='confirmed',confirmed_at=now()
  where id=p_operation_id and status<>'confirmed';
  update public.parking_state
  set entry_gate=case when v_op.direction='entry' then 'closed' else entry_gate end,
      exit_gate=case when v_op.direction='exit' then 'closed' else exit_gate end,
      state_version=state_version+1,updated_at=now()
  where id=1;
  insert into public.audit_events(event_type,vehicle_type,operation_id,reservation_id,source,result,actor_id,details)
  values(
    case when v_op.direction='entry' then 'vehicle_entered' else 'vehicle_exited' end,
    v_op.vehicle_type,p_operation_id,v_op.reservation_id,v_op.source,'success',auth.uid(),
    jsonb_build_object('sensor_clear_ms',p_clear_ms,'terminal_id',v_op.terminal_id,
      'request_origin',v_op.request_origin,
      'controller',case when v_op.source='simulation' then 'simulated-esp8266' else 'esp8266-main' end)
  );
end;
$$;
revoke all on function private.confirm_controller_operation(uuid,integer)
  from public,anon,authenticated,service_role;
