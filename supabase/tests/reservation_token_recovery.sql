begin;
select plan(15);

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_anonymous)
values ('00000000-0000-0000-0000-000000000097', 'authenticated', 'authenticated', 'reservation-recovery-test@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, false)
on conflict (id) do nothing;
insert into public.user_roles (user_id, role)
values ('00000000-0000-0000-0000-000000000097', 'admin')
on conflict (user_id) do update set role = excluded.role;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000097', true);

create temporary table reservation_test_date on commit drop as
select ((now() at time zone 'America/Argentina/Cordoba')::date + candidates.day_offset)::date as reserved_for
from generate_series(1000, 5000) as candidates(day_offset)
where (select count(*) from public.reservations r where r.reserved_for=(now() at time zone 'America/Argentina/Cordoba')::date + candidates.day_offset and r.state not in ('finished','revoked','expired')) < 3
order by candidates.day_offset limit 1;
create temporary table created_token on commit drop as
select r.* from reservation_test_date d cross join lateral public.create_reservation(d.reserved_for) r;

select ok((select access_token ~ '^[0-9]{6}$' from created_token), 'new reservation receives a six-digit token');
select ok((select exists (select 1 from private.reservation_token_ciphertexts c join created_token x on x.reservation_id=c.reservation_id)), 'new token has a private encrypted copy');
select ok((select c.token_ciphertext <> convert_to(x.access_token, 'UTF8') from private.reservation_token_ciphertexts c join created_token x on x.reservation_id=c.reservation_id), 'stored ciphertext is not the plaintext token');
select ok((select t.access_token=x.access_token from created_token x cross join lateral public.admin_reservation_tokens_for_date(x.reserved_for) t where t.reservation_id=x.reservation_id), 'administrator recovery RPC returns the same token after reload');

delete from private.reservation_token_ciphertexts where reservation_id=(select reservation_id from created_token);
select ok((select t.access_token is null from created_token x cross join lateral public.admin_reservation_tokens_for_date(x.reserved_for) t where t.reservation_id=x.reservation_id), 'legacy reservation without ciphertext is reported as unrecoverable, not fabricated');

create temporary table regenerated_token on commit drop as
select * from public.regenerate_reservation_token((select reservation_id from created_token));
select ok((select x.access_token <> n.access_token from created_token x cross join regenerated_token n), 'regeneration issues a different token');
select ok((select not exists (select 1 from private.reservation_token_fingerprints f cross join created_token x where f.token_hmac=private.reservation_token_hmac(x.access_token))), 'the previous token is invalidated');
select ok((select exists (select 1 from private.reservation_token_fingerprints f cross join regenerated_token n where f.reservation_id=n.reservation_id and f.token_hmac=private.reservation_token_hmac(n.access_token))), 'the new HMAC is attached to the same reservation');
select ok((select t.access_token=n.access_token from regenerated_token n join public.reservations r on r.id=n.reservation_id cross join lateral public.admin_reservation_tokens_for_date(r.reserved_for) t where t.reservation_id=n.reservation_id), 'regenerated token is encrypted and recoverable');
select ok((select r.reserved_for=x.reserved_for and r.state='scheduled' and r.version=2 and r.sync_status='confirmed' and r.synced_at is not null from public.reservations r cross join created_token x where r.id=x.reservation_id), 'regeneration preserves date/state and advances the confirmed version');
select ok(not has_table_privilege('authenticated', 'private.reservation_token_ciphertexts', 'select'), 'authenticated clients cannot read ciphertext storage directly');
select ok(not has_function_privilege('anon', 'public.admin_reservation_tokens_for_date(date)', 'execute'), 'anonymous users cannot call token recovery');
select ok(not has_function_privilege('anon', 'public.regenerate_reservation_token(uuid)', 'execute'), 'anonymous users cannot regenerate tokens');

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select throws_ok(
  format('select * from public.admin_reservation_tokens_for_date(%L::date)', (select reserved_for from created_token)),
  '42501', 'administrator role required', 'non-admin cannot recover tokens'
);
select throws_ok(
  format('select * from public.regenerate_reservation_token(%L::uuid)', (select reservation_id from created_token)),
  '42501', 'administrator role required', 'non-admin cannot regenerate tokens'
);

select * from finish();
rollback;
