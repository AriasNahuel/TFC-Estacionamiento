-- Serialize physical vehicle starts and maintenance orders on parking_state.
-- This only prevents overlap with queued/running maintenance; it does not
-- change vehicle authorization, capacity, reservation, or sensor rules.
create or replace function private.prevent_vehicle_operation_during_maintenance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.source = 'device' and new.status in ('pending','detected') then
    perform 1 from public.parking_state where id=1 for update;
    if exists (
      select 1 from public.hardware_commands c
      where c.device_id='esp8266-main' and c.command_type='manual_control'
        and c.status in ('pending','received','running') and c.expires_at>now()
    ) then
      raise exception 'maintenance command in progress' using errcode='55000';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.prevent_vehicle_operation_during_maintenance() from public,anon,authenticated,service_role;

drop trigger if exists prevent_vehicle_operation_during_maintenance on public.vehicle_operations;
create trigger prevent_vehicle_operation_during_maintenance
before insert on public.vehicle_operations
for each row execute function private.prevent_vehicle_operation_during_maintenance();
