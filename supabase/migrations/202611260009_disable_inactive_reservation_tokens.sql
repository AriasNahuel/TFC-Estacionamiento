-- Los tokens completos solo se recuperan para reservas que aún pueden ingresar.
-- Reservas estacionadas, finalizadas, vencidas o revocadas devuelven NULL.
create or replace function public.admin_reservation_tokens_for_date(p_reserved_for date)
returns table (reservation_id uuid, access_token text)
language plpgsql security definer set search_path = '' as $$
declare
  v_key text;
  v_today date := (now() at time zone 'America/Argentina/Cordoba')::date;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'administrator role required' using errcode = '42501';
  end if;
  select ds.decrypted_secret into v_key from vault.decrypted_secrets ds
  where ds.name = 'parking_reservation_token_encryption_v1';
  if v_key is null or length(v_key) <> 64 then
    raise exception 'reservation encryption key is unavailable';
  end if;
  return query
    select r.id,
      case
        when r.reserved_for < v_today or r.state not in ('available', 'scheduled', 'retained') then null::text
        when c.token_ciphertext is null then null::text
        else extensions.pgp_sym_decrypt(c.token_ciphertext, v_key)
      end
    from public.reservations r
    left join private.reservation_token_ciphertexts c on c.reservation_id = r.id
    where r.reserved_for = p_reserved_for
    order by r.created_at, r.id;
end;
$$;
revoke all on function public.admin_reservation_tokens_for_date(date) from public, anon, authenticated, service_role;
grant execute on function public.admin_reservation_tokens_for_date(date) to authenticated;
