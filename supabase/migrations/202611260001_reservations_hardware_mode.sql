-- Las reservas se guardan en la misma base central que consultan ambas terminales.
-- El modo de control (simulado/físico) no cambia la confirmación transaccional.
-- El heartbeat físico sigue siendo requisito de start_terminal_operation.
create or replace function public.create_reservation(p_reserved_for date)
returns table (reservation_id uuid, access_token text, reserved_for date)
language plpgsql security definer set search_path = '' as $$
declare
  v_token text;
  v_token_hmac bytea;
  v_id uuid;
  v_count integer;
  v_random bytea;
  v_value bigint;
  v_attempt integer := 0;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'administrator role required' using errcode = '42501';
  end if;
  if p_reserved_for < (now() at time zone 'America/Argentina/Cordoba')::date then
    raise exception 'reservation date must be today or later' using errcode = '22023';
  end if;

  -- Mantener el lock de configuración y serializar el cupo por fecha.
  perform 1 from public.parking_state where id = 1 for update;
  if not found then
    raise exception 'parking state unavailable' using errcode = '55000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_reserved_for::text, 0));

  select count(*) into v_count
  from public.reservations r
  where r.reserved_for = p_reserved_for
    and r.state not in ('finished', 'revoked', 'expired');
  if v_count >= 3 then
    raise exception 'daily reservation capacity reached' using errcode = '23514';
  end if;

  loop
    v_random := extensions.gen_random_bytes(4);
    v_value := get_byte(v_random, 0)::bigint * 16777216
      + get_byte(v_random, 1)::bigint * 65536
      + get_byte(v_random, 2)::bigint * 256
      + get_byte(v_random, 3)::bigint;
    -- Rechazo del sesgo de módulo: cada token de seis dígitos tiene igual probabilidad.
    if v_value >= 4294000000 then continue; end if;

    v_token := lpad((v_value % 1000000)::text, 6, '0');
    v_token_hmac := private.reservation_token_hmac(v_token);
    v_id := gen_random_uuid();
    v_attempt := v_attempt + 1;
    begin
      insert into public.reservations
        (id, token_suffix, reserved_for, state, created_by, sync_status, version, synced_at)
      values (
        v_id,
        right(v_token, 3),
        p_reserved_for,
        case
          when p_reserved_for = (now() at time zone 'America/Argentina/Cordoba')::date then 'available'
          else 'scheduled'
        end,
        auth.uid(),
        'confirmed',
        1,
        now()
      );
      insert into private.reservation_token_fingerprints (reservation_id, token_hmac)
      values (v_id, v_token_hmac);
      exit;
    exception when unique_violation then
      -- La restricción única global también cubre colisiones entre fechas.
      if v_attempt >= 25 then
        raise exception 'unable to allocate a unique reservation token';
      end if;
    end;
  end loop;

  insert into public.audit_events
    (event_type, reservation_id, source, result, actor_id, details)
  values (
    'reservation_created', v_id, 'admin', 'success', auth.uid(),
    jsonb_build_object('sync_status', 'confirmed')
  );

  return query select v_id, v_token, p_reserved_for;
end;
$$;

revoke all on function public.create_reservation(date) from public, anon, authenticated, service_role;
grant execute on function public.create_reservation(date) to authenticated;
