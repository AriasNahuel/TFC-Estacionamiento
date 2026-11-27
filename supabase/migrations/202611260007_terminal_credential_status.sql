-- Diferenciar revocación de un bloqueo temporal para restaurar credenciales del navegador.
create or replace function public.terminal_credential_status(
  p_terminal_id text,
  p_terminal_secret text,
  p_lane text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enabled boolean;
  v_revoked_at timestamptz;
  v_lane text;
  v_digest bytea;
  v_expires_at timestamptz;
  v_blocked_until timestamptz;
begin
  if p_lane not in ('entry', 'exit') or p_terminal_id is null
     or p_terminal_secret is null or length(p_terminal_secret) < 40 then
    return 'invalid';
  end if;

  select t.enabled, t.revoked_at, t.lane, c.secret_digest, c.expires_at
    into v_enabled, v_revoked_at, v_lane, v_digest, v_expires_at
  from public.terminals t
  left join private.terminal_credentials c using (terminal_id)
  where t.terminal_id = p_terminal_id;

  if not found or not v_enabled or v_revoked_at is not null or v_lane <> p_lane
     or v_expires_at is not null and v_expires_at <= now() then
    return 'revoked';
  end if;

  if v_digest is null or v_digest <> extensions.digest(convert_to(p_terminal_secret, 'UTF8'), 'sha256') then
    perform private.authenticate_terminal(p_terminal_id, p_terminal_secret, p_lane);
    return 'invalid';
  end if;

  select attempts.blocked_until into v_blocked_until
  from private.terminal_attempt_windows attempts
  where attempts.terminal_id = p_terminal_id;
  if v_blocked_until > now() then return 'blocked'; end if;

  if private.authenticate_terminal(p_terminal_id, p_terminal_secret, p_lane) then
    return 'valid';
  end if;
  return 'invalid';
end;
$$;

revoke all on function public.terminal_credential_status(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.terminal_credential_status(text, text, text)
  to anon, authenticated;
