-- La rotación del token cambia la versión de la reserva para que cualquier
-- consumidor de metadatos detecte la invalidación; fecha y estado no cambian.
create or replace function public.regenerate_reservation_token(p_reservation_id uuid)
returns table (reservation_id uuid, access_token text)
language plpgsql security definer set search_path = '' as $$
declare
  v_res public.reservations%rowtype;
  v_token text;
  v_hmac bytea;
  v_ciphertext bytea;
  v_random bytea;
  v_value bigint;
  v_attempt integer := 0;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'administrator role required' using errcode = '42501';
  end if;
  select r.* into v_res from public.reservations r where r.id = p_reservation_id for update;
  if not found then raise exception 'reservation not found' using errcode = 'P0002'; end if;
  if v_res.state not in ('available', 'scheduled', 'retained', 'parked', 'expired_occupied') then
    raise exception 'reservation is not eligible for token regeneration' using errcode = '55000';
  end if;
  loop
    v_random := extensions.gen_random_bytes(4);
    v_value := get_byte(v_random, 0)::bigint * 16777216
      + get_byte(v_random, 1)::bigint * 65536
      + get_byte(v_random, 2)::bigint * 256
      + get_byte(v_random, 3)::bigint;
    if v_value >= 4294000000 then continue; end if;
    v_token := lpad((v_value % 1000000)::text, 6, '0');
    v_hmac := private.reservation_token_hmac(v_token);
    v_ciphertext := private.encrypt_reservation_token(v_token);
    v_attempt := v_attempt + 1;
    begin
      update public.reservations as r
      set token_suffix = right(v_token, 3), updated_at = now(), version = r.version + 1,
          sync_status = 'confirmed', synced_at = now()
      where r.id = v_res.id;
      update private.reservation_token_fingerprints as f set token_hmac = v_hmac
      where f.reservation_id = v_res.id;
      if not found then
        insert into private.reservation_token_fingerprints (reservation_id, token_hmac)
        values (v_res.id, v_hmac);
      end if;
      insert into private.reservation_token_ciphertexts (reservation_id, token_ciphertext, updated_at)
      values (v_res.id, v_ciphertext, now())
      on conflict on constraint reservation_token_ciphertexts_pkey do update
      set token_ciphertext = excluded.token_ciphertext, updated_at = excluded.updated_at;
      exit;
    exception when unique_violation then
      if v_attempt >= 25 then raise exception 'unable to allocate a unique reservation token'; end if;
    end;
  end loop;
  insert into public.audit_events (event_type, reservation_id, source, result, actor_id, details)
  values ('reservation_token_regenerated', v_res.id, 'admin', 'success', auth.uid(), '{}'::jsonb);
  return query select v_res.id, v_token;
end;
$$;
revoke all on function public.regenerate_reservation_token(uuid) from public, anon, authenticated, service_role;
grant execute on function public.regenerate_reservation_token(uuid) to authenticated;
