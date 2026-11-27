-- Recuperación administrativa de tokens: el HMAC continúa siendo la única huella
-- usada para validar; una copia cifrada permite mostrarlos solo vía RPC admin.
-- Vault genera y cifra la clave; nunca queda embebida en SQL, frontend o repositorio.
do $$
begin
  if not exists (
    select 1 from vault.secrets where name = 'parking_reservation_token_encryption_v1'
  ) then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'parking_reservation_token_encryption_v1',
      'Clave AES para tokens cifrados de reservas locales; no compartir ni exportar.'
    );
  end if;
end;
$$;

create table private.reservation_token_ciphertexts (
  reservation_id uuid primary key references public.reservations(id) on delete cascade,
  token_ciphertext bytea not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table private.reservation_token_ciphertexts enable row level security;
revoke all on private.reservation_token_ciphertexts from public, anon, authenticated, service_role;

create or replace function private.encrypt_reservation_token(p_token text)
returns bytea
language plpgsql security definer set search_path = '' as $$
declare
  v_key text;
begin
  if p_token !~ '^[0-9]{6}$' then
    raise exception 'invalid reservation token format' using errcode = '22023';
  end if;
  select ds.decrypted_secret into v_key
  from vault.decrypted_secrets ds
  where ds.name = 'parking_reservation_token_encryption_v1';
  if v_key is null or length(v_key) <> 64 then
    raise exception 'reservation encryption key is unavailable';
  end if;
  return extensions.pgp_sym_encrypt(p_token, v_key, 'cipher-algo=aes256, compress-algo=0');
end;
$$;
revoke all on function private.encrypt_reservation_token(text) from public, anon, authenticated, service_role;

create or replace function public.create_reservation(p_reserved_for date)
returns table (reservation_id uuid, access_token text, reserved_for date)
language plpgsql security definer set search_path = '' as $$
declare
  v_token text;
  v_token_hmac bytea;
  v_token_ciphertext bytea;
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
  perform 1 from public.parking_state where id = 1 for update;
  if not found then raise exception 'parking state unavailable' using errcode = '55000'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_reserved_for::text, 0));

  select count(*) into v_count from public.reservations r
  where r.reserved_for = p_reserved_for and r.state not in ('finished', 'revoked', 'expired');
  if v_count >= 3 then raise exception 'daily reservation capacity reached' using errcode = '23514'; end if;

  loop
    v_random := extensions.gen_random_bytes(4);
    v_value := get_byte(v_random, 0)::bigint * 16777216
      + get_byte(v_random, 1)::bigint * 65536
      + get_byte(v_random, 2)::bigint * 256
      + get_byte(v_random, 3)::bigint;
    if v_value >= 4294000000 then continue; end if;
    v_token := lpad((v_value % 1000000)::text, 6, '0');
    v_token_hmac := private.reservation_token_hmac(v_token);
    v_token_ciphertext := private.encrypt_reservation_token(v_token);
    v_id := gen_random_uuid();
    v_attempt := v_attempt + 1;
    begin
      insert into public.reservations
        (id, token_suffix, reserved_for, state, created_by, sync_status, version, synced_at)
      values (
        v_id, right(v_token, 3), p_reserved_for,
        case when p_reserved_for = (now() at time zone 'America/Argentina/Cordoba')::date then 'available' else 'scheduled' end,
        auth.uid(), 'confirmed', 1, now()
      );
      insert into private.reservation_token_fingerprints (reservation_id, token_hmac)
      values (v_id, v_token_hmac);
      insert into private.reservation_token_ciphertexts (reservation_id, token_ciphertext)
      values (v_id, v_token_ciphertext);
      exit;
    exception when unique_violation then
      if v_attempt >= 25 then raise exception 'unable to allocate a unique reservation token'; end if;
    end;
  end loop;

  insert into public.audit_events (event_type, reservation_id, source, result, actor_id, details)
  values ('reservation_created', v_id, 'admin', 'success', auth.uid(), jsonb_build_object('sync_status', 'confirmed'));
  return query select v_id, v_token, p_reserved_for;
end;
$$;
revoke all on function public.create_reservation(date) from public, anon, authenticated, service_role;
grant execute on function public.create_reservation(date) to authenticated;

-- Esta operación administrativa devuelve solo tokens de una fecha solicitada.
-- Los registros legacy sin ciphertext reciben NULL y requieren regeneración.
create or replace function public.admin_reservation_tokens_for_date(p_reserved_for date)
returns table (reservation_id uuid, access_token text)
language plpgsql security definer set search_path = '' as $$
declare
  v_key text;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'administrator role required' using errcode = '42501';
  end if;
  select ds.decrypted_secret into v_key from vault.decrypted_secrets ds
  where ds.name = 'parking_reservation_token_encryption_v1';
  if v_key is null or length(v_key) <> 64 then raise exception 'reservation encryption key is unavailable'; end if;
  return query
    select r.id,
      case when c.token_ciphertext is null then null::text
           else extensions.pgp_sym_decrypt(c.token_ciphertext, v_key) end
    from public.reservations r
    left join private.reservation_token_ciphertexts c on c.reservation_id = r.id
    where r.reserved_for = p_reserved_for
    order by r.created_at, r.id;
end;
$$;
revoke all on function public.admin_reservation_tokens_for_date(date) from public, anon, authenticated, service_role;
grant execute on function public.admin_reservation_tokens_for_date(date) to authenticated;

-- Regenera solo reservas aún útiles. El UPDATE del HMAC invalida atómicamente
-- el token previo sin alterar la reserva, su fecha, vencimiento ni operaciones.
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
      update public.reservations set token_suffix = right(v_token, 3), updated_at = now()
      where id = v_res.id;
      update private.reservation_token_fingerprints set token_hmac = v_hmac
      where reservation_id = v_res.id;
      if not found then
        insert into private.reservation_token_fingerprints (reservation_id, token_hmac)
        values (v_res.id, v_hmac);
      end if;
      insert into private.reservation_token_ciphertexts (reservation_id, token_ciphertext, updated_at)
      values (v_res.id, v_ciphertext, now())
      on conflict (reservation_id) do update
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
