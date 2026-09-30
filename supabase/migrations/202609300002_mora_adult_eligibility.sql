-- Account-bound, explicit adult self-attestation. No date of birth, identity
-- document, IP address, or record of a declined answer is collected.
-- The environment FK also erases this record during the data-purge phase of
-- account deletion, before the later Auth deletion. Auth deletion cascades
-- through account_environment as a second deletion path. No retention copy.
create table if not exists mora_internal.adult_eligibility (
  user_id uuid primary key references mora_internal.account_environment(user_id) on delete cascade,
  policy_version text not null check (length(policy_version) between 1 and 64),
  accepted_at timestamptz not null default clock_timestamp()
);

alter table mora_internal.adult_eligibility enable row level security;
revoke all on mora_internal.adult_eligibility from public, anon, authenticated, service_role;

create or replace function public.get_adult_eligibility()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, auth, mora_internal
as $$
declare
  v_user_id uuid := auth.uid();
  v_policy_version constant text := 'adult-v1';
begin
  if v_user_id is null or (auth.jwt() ->> 'role') is distinct from 'authenticated' then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  -- Preserve the existing trusted environment binding and deletion lock.
  perform mora_internal.resolve_environment(v_user_id);
  return jsonb_build_object(
    'eligible', exists (
      select 1 from mora_internal.adult_eligibility
       where user_id = v_user_id and policy_version = v_policy_version
    ),
    'policyVersion', v_policy_version
  );
end;
$$;

create or replace function public.accept_adult_eligibility(p_policy_version text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, auth, mora_internal
as $$
declare
  v_user_id uuid := auth.uid();
  v_policy_version constant text := 'adult-v1';
begin
  if v_user_id is null or (auth.jwt() ->> 'role') is distinct from 'authenticated' then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if p_policy_version is distinct from v_policy_version then
    raise exception 'unsupported_adult_policy_version' using errcode = '22023';
  end if;
  perform mora_internal.resolve_environment(v_user_id);
  insert into mora_internal.adult_eligibility as existing (user_id, policy_version)
  values (v_user_id, v_policy_version)
  on conflict (user_id) do update
    set policy_version = excluded.policy_version,
        accepted_at = clock_timestamp()
    where existing.policy_version is distinct from excluded.policy_version;
  return jsonb_build_object('eligible', true, 'policyVersion', v_policy_version);
end;
$$;

revoke all on function public.get_adult_eligibility() from public, anon, service_role;
revoke all on function public.accept_adult_eligibility(text) from public, anon, service_role;
grant execute on function public.get_adult_eligibility() to authenticated;
grant execute on function public.accept_adult_eligibility(text) to authenticated;
