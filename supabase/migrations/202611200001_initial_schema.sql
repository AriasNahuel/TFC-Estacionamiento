-- Esquema inicial para Supabase. Las terminales no escriben directamente en tablas.
-- Requiere Supabase Vault (disponible en proyectos Supabase) y pgcrypto.
create extension if not exists supabase_vault with schema vault;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated, service_role;
grant usage on schema private to authenticated;
grant usage on schema public to authenticated;

-- La clave HMAC se genera una sola vez en el servidor y queda cifrada por Vault.
-- No imprimir ni seleccionar decrypted_secret fuera de la función privada.
do $$
begin
  if not exists (
    select 1 from vault.secrets where name = 'parking_reservation_token_hmac_v1'
  ) then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'parking_reservation_token_hmac_v1',
      'Clave HMAC para huellas de tokens de reserva; no rotar sin migrar tokens activos.'
    );
  end if;
end;
$$;

-- Ningún rol de la Data API, incluido service_role, puede consultar secretos Vault.
revoke all on schema vault from public, anon, authenticated, service_role;
revoke all on all tables in schema vault from public, anon, authenticated, service_role;
revoke all on all sequences in schema vault from public, anon, authenticated, service_role;
grant usage on schema vault to postgres;
grant select on vault.decrypted_secrets to postgres;

create table public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin')),
  created_at timestamptz not null default now()
);
alter table public.user_roles enable row level security;

-- La tabla no tiene políticas ni grants para usuarios de API. La asignación inicial
-- y futuros cambios de rol se realizan desde SQL Editor por un operador confiable.
create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.user_roles ur
    where ur.user_id = (select auth.uid()) and ur.role = 'admin'
  );
$$;
revoke all on function private.is_admin() from public, anon, authenticated, service_role;
grant execute on function private.is_admin() to authenticated;

create table public.parking_state (
  id smallint primary key default 1 check (id = 1),
  regular_count integer not null default 0 check (regular_count between 0 and 7),
  reserved_count integer not null default 0 check (reserved_count between 0 and 3),
  temporary_count integer not null default 0 check (temporary_count >= 0),
  simulation_mode boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into public.parking_state (id) values (1) on conflict (id) do nothing;

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  token_suffix text not null check (token_suffix ~ '^[0-9]{3}$'),
  reserved_for date not null,
  state text not null check (state in ('scheduled','available','parked','retained','finished','revoked','expired','expired_occupied')),
  vehicle_present boolean not null default false,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (not vehicle_present or state in ('parked','expired_occupied'))
);
create index reservations_date_state_idx on public.reservations (reserved_for, state);

-- Las huellas están en un esquema no expuesto y sin grants a roles de cliente.
-- HMAC-SHA-256 con clave aleatoria de Vault evita hashes atacables por diccionario
-- si se filtra un dump de esta tabla sin la clave Vault.
create table private.reservation_token_fingerprints (
  reservation_id uuid primary key references public.reservations(id) on delete cascade,
  token_hmac bytea not null unique
);
alter table private.reservation_token_fingerprints enable row level security;
revoke all on private.reservation_token_fingerprints from public, anon, authenticated, service_role;

create or replace function private.reservation_token_hmac(p_token text)
returns bytea
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_key_hex text;
begin
  if p_token !~ '^[0-9]{6}$' then
    raise exception 'invalid reservation token format' using errcode = '22023';
  end if;

  select ds.decrypted_secret into v_key_hex
  from vault.decrypted_secrets ds
  where ds.name = 'parking_reservation_token_hmac_v1';

  if v_key_hex is null or length(v_key_hex) <> 64 then
    raise exception 'reservation token key is unavailable';
  end if;

  return extensions.hmac(convert_to(p_token, 'UTF8'), decode(v_key_hex, 'hex'), 'sha256');
end;
$$;
revoke all on function private.reservation_token_hmac(text) from public, anon, authenticated, service_role;

create table public.vehicle_operations (
  id uuid primary key default gen_random_uuid(),
  direction text not null check (direction in ('entry','exit')),
  vehicle_type text not null check (vehicle_type in ('regular','reserved','temporary')),
  reservation_id uuid references public.reservations(id),
  status text not null check (status in ('pending','detected','confirmed','failed','cancelled')),
  source text not null check (source in ('simulation','device','admin')),
  reservation_action text check (reservation_action in ('retain','finish')),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  idempotency_key uuid not null unique,
  check ((vehicle_type = 'reserved') = (reservation_id is not null))
);
create unique index one_active_operation_per_lane on public.vehicle_operations (direction) where status in ('pending','detected');

create table public.audit_events (
  id bigint generated always as identity primary key,
  event_type text not null,
  vehicle_type text check (vehicle_type in ('regular','reserved','temporary')),
  operation_id uuid references public.vehicle_operations(id),
  reservation_id uuid references public.reservations(id),
  source text not null check (source in ('simulation','device','admin','system')),
  result text not null,
  details jsonb not null default '{}'::jsonb,
  actor_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index audit_events_created_idx on public.audit_events (created_at desc);

create table public.device_state (
  device_id text primary key,
  connected boolean not null default false,
  last_heartbeat timestamptz,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table public.hardware_commands (
  id uuid primary key default gen_random_uuid(),
  device_id text not null references public.device_state(device_id),
  operation_id uuid references public.vehicle_operations(id),
  command_type text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','received','running','confirmed','failed','cancelled')),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  acknowledged_at timestamptz,
  result jsonb not null default '{}'::jsonb,
  check (expires_at > issued_at)
);
create index hardware_commands_pending_idx on public.hardware_commands (device_id, status, issued_at);

alter table public.parking_state enable row level security;
alter table public.reservations enable row level security;
alter table public.vehicle_operations enable row level security;
alter table public.audit_events enable row level security;
alter table public.device_state enable row level security;
alter table public.hardware_commands enable row level security;

create policy "admins read parking state" on public.parking_state
  for select to authenticated using ((select private.is_admin()));
create policy "admins read reservations" on public.reservations
  for select to authenticated using ((select private.is_admin()));
create policy "admins read vehicle operations" on public.vehicle_operations
  for select to authenticated using ((select private.is_admin()));
create policy "admins read audit events" on public.audit_events
  for select to authenticated using ((select private.is_admin()));
create policy "admins read device state" on public.device_state
  for select to authenticated using ((select private.is_admin()));
create policy "admins read hardware commands" on public.hardware_commands
  for select to authenticated using ((select private.is_admin()));

-- Vista de solo lectura para administración. El vencimiento es derivado en la zona
-- horaria del estacionamiento: un vehículo presente nunca deja de poder egresar.
create view public.reservation_admin_view
with (security_invoker = true)
as
select
  r.id,
  r.token_suffix,
  r.reserved_for,
  case
    when r.vehicle_present and r.reserved_for < (now() at time zone 'America/Argentina/Cordoba')::date then 'expired_occupied'
    when not r.vehicle_present and r.reserved_for < (now() at time zone 'America/Argentina/Cordoba')::date
      and r.state not in ('finished','revoked') then 'expired'
    else r.state
  end as effective_state,
  r.vehicle_present,
  r.created_at,
  r.updated_at
from public.reservations r;

-- Explicit grants: una migración no depende de “Automatically expose new tables”.
revoke all on table public.user_roles, public.parking_state, public.reservations,
  public.vehicle_operations, public.audit_events, public.device_state,
  public.hardware_commands, public.reservation_admin_view
  from public, anon, authenticated, service_role;
grant select on table public.parking_state, public.reservations,
  public.vehicle_operations, public.audit_events, public.device_state,
  public.hardware_commands, public.reservation_admin_view to authenticated;

-- El rol postgres ejecuta las migraciones; futuras funciones quedan cerradas por
-- defecto. Cada RPC debe revocar PUBLIC y conceder EXECUTE explícitamente.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated, service_role;
alter default privileges for role postgres in schema private
  revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema private
  revoke all on sequences from anon, authenticated, service_role;
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated, service_role;
alter default privileges for role postgres in schema private
  revoke execute on functions from anon, authenticated, service_role;

create or replace function public.create_reservation(p_reserved_for date)
returns table (reservation_id uuid, access_token text, reserved_for date)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_token_hmac bytea;
  v_id uuid;
  v_count integer;
  v_random bytea;
  v_random_value bigint;
  v_attempt integer := 0;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'administrator role required' using errcode = '42501';
  end if;
  if p_reserved_for < (now() at time zone 'America/Argentina/Cordoba')::date then
    raise exception 'reservation date must be today or later' using errcode = '22023';
  end if;

  -- Serializa la cuota de la fecha; el índice unique global resuelve colisiones
  -- incluso si dos fechas se procesan en paralelo.
  perform pg_advisory_xact_lock(hashtextextended(p_reserved_for::text, 0));
  select count(*) into v_count
  from public.reservations r
  where r.reserved_for = p_reserved_for and r.state not in ('finished','revoked','expired');
  if v_count >= 3 then
    raise exception 'daily reservation capacity reached' using errcode = '23514';
  end if;

  loop
    v_random := extensions.gen_random_bytes(4);
    v_random_value := (get_byte(v_random, 0)::bigint * 16777216
      + get_byte(v_random, 1)::bigint * 65536
      + get_byte(v_random, 2)::bigint * 256
      + get_byte(v_random, 3)::bigint);
    -- Rechazo del sesgo de módulo en el espacio de 2^32 valores.
    if v_random_value >= 4294000000 then continue; end if;
    v_token := lpad((v_random_value % 1000000)::text, 6, '0');
    v_token_hmac := private.reservation_token_hmac(v_token);
    v_id := gen_random_uuid();
    v_attempt := v_attempt + 1;
    begin
      insert into public.reservations (id, token_suffix, reserved_for, state, created_by)
      values (
        v_id,
        right(v_token, 3),
        p_reserved_for,
        case when p_reserved_for = (now() at time zone 'America/Argentina/Cordoba')::date then 'available' else 'scheduled' end,
        auth.uid()
      );
      insert into private.reservation_token_fingerprints (reservation_id, token_hmac)
      values (v_id, v_token_hmac);
      exit;
    exception when unique_violation then
      -- Un token ya asignado (también en otra fecha): revierte ambas inserciones
      -- del bloque y vuelve a generar; nunca devuelve ni pierde una colisión.
      if v_attempt >= 25 then
        raise exception 'unable to allocate a unique reservation token';
      end if;
    end;
  end loop;

  insert into public.audit_events (event_type, reservation_id, source, result, actor_id)
  values ('reservation_created', v_id, 'admin', 'success', auth.uid());
  return query select v_id, v_token, p_reserved_for;
end;
$$;
revoke all on function public.create_reservation(date) from public, anon, authenticated, service_role;
grant execute on function public.create_reservation(date) to authenticated;

-- CREATE FUNCTION otorga EXECUTE a PUBLIC inicialmente. Aseguramos explícitamente
-- que la rutina HMAC tampoco sea invocable desde ninguna API.
revoke all on function private.reservation_token_hmac(text) from public, anon, authenticated, service_role;

