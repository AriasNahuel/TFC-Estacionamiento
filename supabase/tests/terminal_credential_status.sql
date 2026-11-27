begin;
select plan(5);

select ok(
  has_function_privilege('anon', 'public.terminal_credential_status(text,text,text)', 'execute')
  and has_function_privilege('authenticated', 'public.terminal_credential_status(text,text,text)', 'execute')
  and not has_function_privilege('service_role', 'public.terminal_credential_status(text,text,text)', 'execute'),
  'credential status RPC is available to terminal clients without a service-role grant'
);

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_anonymous)
values ('00000000-0000-0000-0000-000000000097', 'authenticated', 'authenticated', 'terminal-status-test@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, false)
on conflict (id) do nothing;
insert into public.user_roles (user_id, role)
values ('00000000-0000-0000-0000-000000000097', 'admin')
on conflict (user_id) do update set role = excluded.role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000097', true);

create temporary table status_test_terminal on commit drop as
select * from public.provision_terminal('terminal-status-test', 'entry');

select is(
  (select public.terminal_credential_status(terminal_id, terminal_secret, 'entry') from status_test_terminal),
  'valid', 'valid terminal credentials are accepted'
);
select is(
  (select public.terminal_credential_status(terminal_id, repeat('x', 64), 'entry') from status_test_terminal),
  'invalid', 'incorrect credentials are reported as invalid'
);
select public.terminal_credential_status(terminal_id, repeat('x', 64), 'entry')
from status_test_terminal, generate_series(1, 4);
select is(
  (select public.terminal_credential_status(terminal_id, terminal_secret, 'entry') from status_test_terminal),
  'blocked', 'temporary attempt lock is distinguishable and does not invalidate the right credential'
);
select public.revoke_terminal('terminal-status-test');
select is(
  (select public.terminal_credential_status(terminal_id, terminal_secret, 'entry') from status_test_terminal),
  'revoked', 'revoked credentials are reported distinctly for local deletion'
);

select * from finish();
rollback;
