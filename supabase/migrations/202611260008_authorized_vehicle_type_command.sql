-- La placa recibe el tipo que la RPC ya autorizó para esta operación.
-- No cambia validaciones, origen, vencimiento ni lógica transaccional.
create or replace function public.start_terminal_operation(
  p_terminal_id text,
  p_terminal_secret text,
  p_direction text,
  p_vehicle text,
  p_reservation_token text default null,
  p_action text default 'finish',
  p_idempotency_key uuid default gen_random_uuid()
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_res uuid;
  v_hmac bytea;
  v_op uuid;
  v_source text;
  v_mode boolean;
begin
  if not private.authenticate_terminal(p_terminal_id, p_terminal_secret, p_direction) then
    return null;
  end if;

  select ps.simulation_mode into v_mode from public.parking_state ps where ps.id = 1;
  if not found then return null; end if;

  if v_mode then
    if not exists (
      select 1 from public.device_state d
      where d.device_id = 'simulated-esp8266' and d.connected
    ) then return null; end if;
    v_source := 'simulation';
  else
    if not exists (
      select 1 from public.device_state d
      where d.device_id = 'esp8266-main' and d.connected
        and d.last_heartbeat > now() - interval '30 seconds'
    ) then return null; end if;
    v_source := 'device';
  end if;

  if p_vehicle = 'reserved' then
    if not private.allow_terminal_token_attempt(p_terminal_id)
       or p_reservation_token !~ '^[0-9]{6}$' then
      return null;
    end if;
    v_hmac := private.reservation_token_hmac(p_reservation_token);
    select f.reservation_id into v_res
      from private.reservation_token_fingerprints f
      where f.token_hmac = v_hmac;
    if v_res is null then return null; end if;
  end if;

  begin
    v_op := private.begin_operation(
      p_direction, p_vehicle, v_res, p_action, p_idempotency_key, v_source, p_terminal_id
    );
    if v_source = 'device' then
      insert into public.hardware_commands(device_id, operation_id, command_type, payload, expires_at)
      values (
        'esp8266-main', v_op, 'open_gate',
        jsonb_build_object('direction', p_direction, 'vehicle_type', p_vehicle),
        now() + interval '60 seconds'
      ) on conflict do nothing;
    end if;
    return v_op;
  exception when others then
    return null;
  end;
end;
$$;

revoke all on function public.start_terminal_operation(text, text, text, text, text, text, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.start_terminal_operation(text, text, text, text, text, text, uuid)
  to anon, authenticated;
