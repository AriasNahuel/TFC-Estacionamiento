-- Revoking a reservation is an administrator-only database action; it does not
-- synchronize with either the simulator or the physical ESP8266.
create or replace function public.revoke_reservation(p_reservation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res public.reservations%rowtype;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'administrator role required' using errcode='42501';
  end if;

  select * into v_res
  from public.reservations
  where id = p_reservation_id
  for update;

  if not found or v_res.state in ('finished','revoked','expired') then
    return;
  end if;

  if v_res.vehicle_present then
    raise exception 'cannot revoke a reservation while its vehicle is present' using errcode='55000';
  end if;

  update public.reservations
  set state = 'revoked',
      sync_status = 'confirmed',
      version = version + 1,
      synced_at = now(),
      updated_at = now()
  where id = p_reservation_id;

  insert into public.audit_events(event_type,reservation_id,source,result,actor_id)
  values('reservation_revoked',p_reservation_id,'admin','success',auth.uid());
end;
$$;

revoke all on function public.revoke_reservation(uuid) from public, anon, authenticated, service_role;
grant execute on function public.revoke_reservation(uuid) to authenticated;
