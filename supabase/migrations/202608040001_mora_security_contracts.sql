-- Mora server-side security contracts.
-- The application data itself remains local; these schemas only contain
-- quota, commerce, deletion, and operational-security state.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists mora_internal;
create schema if not exists mora_prod_private;
create schema if not exists mora_stage_private;

revoke all on schema mora_internal from public, anon, authenticated;
revoke all on schema mora_prod_private from public, anon, authenticated;
revoke all on schema mora_stage_private from public, anon, authenticated;

create table if not exists mora_internal.account_environment (
  user_id uuid primary key references auth.users(id) on delete cascade,
  environment text not null check (environment in ('production', 'staging')),
  bound_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

alter table mora_internal.account_environment enable row level security;
revoke all on mora_internal.account_environment from public, anon, authenticated;

-- This lock is created before any destructive deletion step. Existing account
-- RPCs consult it so a partially deleted account cannot resume normal use.
create table if not exists mora_internal.account_deletion_locks (
  user_id uuid primary key references auth.users(id) on delete cascade,
  job_id uuid not null,
  environment text not null check (environment in ('production', 'staging')),
  created_at timestamptz not null default clock_timestamp()
);

alter table mora_internal.account_deletion_locks enable row level security;
revoke all on mora_internal.account_deletion_locks from public, anon, authenticated;

-- app_metadata is writable only by a trusted server/admin. Missing metadata is
-- deliberately routed to production; clients never choose a schema in a body.
create or replace function mora_internal.resolve_environment(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal
as $$
declare
  v_claim text;
  v_bound text;
begin
  if p_user_id is null or p_user_id is distinct from auth.uid() then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if exists (
    select 1
      from mora_internal.account_deletion_locks
     where user_id = p_user_id
  ) then
    raise exception 'account_deletion_pending' using errcode = '42501';
  end if;

  v_claim := coalesce(
    auth.jwt() #>> '{app_metadata,mora_environment}',
    'production'
  );
  if v_claim not in ('production', 'staging') then
    raise exception 'invalid_environment_claim' using errcode = '22023';
  end if;

  insert into mora_internal.account_environment (user_id, environment)
  values (p_user_id, v_claim)
  on conflict (user_id) do nothing;

  select environment
    into v_bound
    from mora_internal.account_environment
   where user_id = p_user_id;

  if v_bound is distinct from v_claim then
    raise exception 'environment_binding_mismatch' using errcode = '42501';
  end if;

  return v_bound;
end;
$$;

revoke all on function mora_internal.resolve_environment(uuid) from public, anon, authenticated;

do $$
declare
  target_schema text;
begin
  foreach target_schema in array array['mora_prod_private', 'mora_stage_private']
  loop
    execute format($ddl$
      create table if not exists %I.ai_daily_quota (
        user_id uuid not null references auth.users(id) on delete cascade,
        usage_date date not null,
        successful_count integer not null default 0 check (successful_count >= 0),
        reserved_count integer not null default 0 check (reserved_count >= 0),
        updated_at timestamptz not null default clock_timestamp(),
        primary key (user_id, usage_date)
      )
    $ddl$, target_schema);

    execute format($ddl$
      create table if not exists %I.ai_analysis_requests (
        user_id uuid not null references auth.users(id) on delete cascade,
        request_id uuid not null,
        usage_date date not null,
        input_hash text not null check (input_hash ~ '^[0-9a-f]{64}$'),
        status text not null check (status in ('reserved', 'succeeded', 'failed')),
        counts_against_quota boolean not null,
        attempt_count integer not null default 1 check (attempt_count between 1 and 3),
        reserved_at timestamptz not null default clock_timestamp(),
        reservation_expires_at timestamptz not null,
        completed_at timestamptz,
        failure_code text,
        retryable boolean not null default false,
        validated_calls jsonb check (
          validated_calls is null or jsonb_typeof(validated_calls) = 'array'
        ),
        response_expires_at timestamptz,
        primary key (user_id, request_id)
      )
    $ddl$, target_schema);

    execute format(
      'create index if not exists %I on %I.ai_analysis_requests (reservation_expires_at) where status = ''reserved''',
      target_schema || '_ai_request_expiry_idx',
      target_schema
    );

    execute format(
      'create index if not exists %I on %I.ai_analysis_requests (completed_at) where status in (''succeeded'', ''failed'')',
      target_schema || '_ai_request_retention_idx',
      target_schema
    );

    execute format(
      'create index if not exists %I on %I.ai_analysis_requests (response_expires_at) where validated_calls is not null',
      target_schema || '_ai_response_expiry_idx',
      target_schema
    );

    execute format(
      'create index if not exists %I on %I.ai_daily_quota (usage_date)',
      target_schema || '_ai_daily_retention_idx',
      target_schema
    );

    execute format($ddl$
      create table if not exists %I.storekit_accounts (
        user_id uuid primary key references auth.users(id) on delete cascade,
        app_account_token uuid not null unique default gen_random_uuid(),
        created_at timestamptz not null default clock_timestamp(),
        updated_at timestamptz not null default clock_timestamp()
      )
    $ddl$, target_schema);

    execute format($ddl$
      create table if not exists %I.account_entitlements (
        user_id uuid primary key references auth.users(id) on delete cascade,
        product_id text,
        status text not null default 'none'
          check (status in ('none', 'active', 'grace', 'billing_retry', 'expired', 'revoked', 'refunded')),
        verified_at timestamptz,
        expires_at timestamptz,
        grace_expires_at timestamptz,
        access_until timestamptz,
        original_transaction_id text,
        updated_at timestamptz not null default clock_timestamp(),
        check (
          (status = 'active' and access_until is not null)
          or (status = 'grace' and access_until is not null and grace_expires_at is not null)
          or status in ('none', 'billing_retry', 'expired', 'revoked', 'refunded')
        )
      )
    $ddl$, target_schema);

    execute format($ddl$
      create table if not exists %I.storekit_transaction_bindings (
        apple_environment text not null check (apple_environment in ('Sandbox', 'Production')),
        original_transaction_id text not null,
        latest_transaction_id text,
        user_id uuid references auth.users(id) on delete set null,
        app_account_token uuid,
        product_id text not null,
        state text not null
          check (state in ('active', 'grace', 'billing_retry', 'expired', 'revoked', 'refunded')),
        purchased_at timestamptz,
        expires_at timestamptz,
        grace_expires_at timestamptz,
        revoked_at timestamptz,
        verified_at timestamptz not null,
        bound_at timestamptz not null default clock_timestamp(),
        updated_at timestamptz not null default clock_timestamp(),
        primary key (apple_environment, original_transaction_id)
      )
    $ddl$, target_schema);

    execute format(
      'create index if not exists %I on %I.storekit_transaction_bindings (user_id) where user_id is not null',
      target_schema || '_storekit_binding_user_idx',
      target_schema
    );

    execute format($ddl$
      create table if not exists %I.storekit_rebind_markers (
        apple_environment text not null check (apple_environment in ('Sandbox', 'Production')),
        original_transaction_id text not null,
        deleted_account_marker text not null,
        deletion_job_id uuid not null,
        eligible_at timestamptz not null,
        consumed_by_user_id uuid references auth.users(id) on delete set null,
        consumed_at timestamptz,
        retain_until timestamptz not null,
        primary key (apple_environment, original_transaction_id),
        check ((consumed_at is null) = (consumed_by_user_id is null))
      )
    $ddl$, target_schema);

    execute format(
      'create index if not exists %I on %I.storekit_rebind_markers (retain_until)',
      target_schema || '_rebind_retention_idx',
      target_schema
    );

    execute format($ddl$
      create table if not exists %I.app_store_notification_events (
        notification_uuid uuid primary key,
        notification_type text not null,
        subtype text,
        apple_environment text not null check (apple_environment in ('Sandbox', 'Production')),
        received_at timestamptz not null default clock_timestamp(),
        processed_at timestamptz,
        failure_code text,
        expires_at timestamptz not null default (clock_timestamp() + interval '90 days')
      )
    $ddl$, target_schema);

    execute format(
      'create index if not exists %I on %I.app_store_notification_events (expires_at)',
      target_schema || '_app_store_event_expiry_idx',
      target_schema
    );

    execute format($ddl$
      create table if not exists %I.account_deletion_jobs (
        job_id uuid primary key default gen_random_uuid(),
        user_id uuid,
        idempotency_key uuid not null,
        environment text not null,
        status_token_hash text not null,
        account_marker text not null unique default encode(extensions.gen_random_bytes(32), 'hex'),
        status text not null default 'requested'
          check (status in ('requested', 'running', 'retry_wait', 'completed', 'failed')),
        attempt_count integer not null default 0 check (attempt_count >= 0),
        apple_revoked_at timestamptz,
        data_purged_at timestamptz,
        auth_deleted_at timestamptz,
        lease_expires_at timestamptz,
        requires_apple_reauth boolean not null default false,
        accepted_at timestamptz not null default clock_timestamp(),
        updated_at timestamptz not null default clock_timestamp(),
        next_attempt_at timestamptz,
        completed_at timestamptz,
        failure_code text,
        unique (user_id, idempotency_key),
        check (status <> 'completed' or (completed_at is not null and user_id is null))
      )
    $ddl$, target_schema);

    -- Keep this migration re-runnable against databases that received an
    -- earlier draft of the deletion table.
    execute format(
      'alter table %I.account_deletion_jobs add column if not exists environment text',
      target_schema
    );
    execute format(
      'alter table %I.account_deletion_jobs add column if not exists status_token_hash text',
      target_schema
    );
    execute format(
      'alter table %I.account_deletion_jobs add column if not exists apple_revoked_at timestamptz',
      target_schema
    );
    execute format(
      'alter table %I.account_deletion_jobs add column if not exists data_purged_at timestamptz',
      target_schema
    );
    execute format(
      'alter table %I.account_deletion_jobs add column if not exists auth_deleted_at timestamptz',
      target_schema
    );
    execute format(
      'alter table %I.account_deletion_jobs add column if not exists lease_expires_at timestamptz',
      target_schema
    );
    execute format(
      'alter table %I.account_deletion_jobs add column if not exists requires_apple_reauth boolean not null default false',
      target_schema
    );
    execute format(
      'update %I.account_deletion_jobs set environment = ''production'' where environment is null',
      target_schema
    );
    execute format(
      'update %I.account_deletion_jobs set status_token_hash = encode(extensions.gen_random_bytes(32), ''hex'') where status_token_hash is null',
      target_schema
    );
    execute format(
      'alter table %I.account_deletion_jobs alter column environment set not null, alter column status_token_hash set not null',
      target_schema
    );
    if not exists (
      select 1
        from pg_constraint c
        join pg_class t on t.oid = c.conrelid
        join pg_namespace n on n.oid = t.relnamespace
       where n.nspname = target_schema
         and t.relname = 'account_deletion_jobs'
         and c.conname = 'account_deletion_jobs_environment_check'
    ) then
      execute format(
        'alter table %I.account_deletion_jobs add constraint account_deletion_jobs_environment_check check (environment in (''production'', ''staging''))',
        target_schema
      );
    end if;
    if not exists (
      select 1
        from pg_constraint c
        join pg_class t on t.oid = c.conrelid
        join pg_namespace n on n.oid = t.relnamespace
       where n.nspname = target_schema
         and t.relname = 'account_deletion_jobs'
         and c.conname = 'account_deletion_jobs_status_token_hash_check'
    ) then
      execute format(
        'alter table %I.account_deletion_jobs add constraint account_deletion_jobs_status_token_hash_check check (status_token_hash ~ ''^[0-9a-f]{64}$'')',
        target_schema
      );
    end if;

    execute format(
      'create unique index if not exists %I on %I.account_deletion_jobs (user_id) where user_id is not null and status in (''requested'', ''running'', ''retry_wait'')',
      target_schema || '_active_deletion_user_idx',
      target_schema
    );

    execute format(
      'create unique index if not exists %I on %I.account_deletion_jobs (idempotency_key)',
      target_schema || '_deletion_request_idx',
      target_schema
    );

    execute format(
      'create unique index if not exists %I on %I.account_deletion_jobs (status_token_hash)',
      target_schema || '_deletion_status_token_idx',
      target_schema
    );

    execute format($ddl$
      create table if not exists %I.account_deletion_receipts (
        job_id uuid primary key references %I.account_deletion_jobs(job_id) on delete cascade,
        account_marker text not null unique,
        completed_at timestamptz not null,
        expires_at timestamptz not null default (clock_timestamp() + interval '30 days')
      )
    $ddl$, target_schema, target_schema);

    execute format(
      'create index if not exists %I on %I.account_deletion_receipts (expires_at)',
      target_schema || '_deletion_receipt_expiry_idx',
      target_schema
    );

    execute format($ddl$
      create table if not exists %I.operational_events (
        event_id bigint generated always as identity primary key,
        user_id uuid references auth.users(id) on delete set null,
        request_id uuid not null,
        event_name text not null
          check (event_name in ('analysis_succeeded', 'analysis_failed', 'quota_denied', 'account_deletion')),
        status_code integer not null check (status_code between 100 and 599),
        duration_ms integer check (duration_ms is null or duration_ms >= 0),
        input_length integer check (input_length is null or input_length between 0 and 1000),
        output_count integer check (output_count is null or output_count between 0 and 50),
        failure_code text,
        occurred_at timestamptz not null default clock_timestamp(),
        expires_at timestamptz not null default (clock_timestamp() + interval '14 days'),
        unique (user_id, request_id, event_name)
      )
    $ddl$, target_schema);

    execute format(
      'create index if not exists %I on %I.operational_events (expires_at, event_id)',
      target_schema || '_operational_event_expiry_idx',
      target_schema
    );

    execute format($ddl$
      create table if not exists %I.daily_operational_aggregates (
        metric_date date not null,
        event_name text not null,
        status_class text not null,
        event_count bigint not null check (event_count >= 0),
        total_duration_ms bigint not null default 0 check (total_duration_ms >= 0),
        max_duration_ms integer not null default 0 check (max_duration_ms >= 0),
        updated_at timestamptz not null default clock_timestamp(),
        expires_at timestamptz not null,
        primary key (metric_date, event_name, status_class)
      )
    $ddl$, target_schema);

    execute format(
      'create index if not exists %I on %I.daily_operational_aggregates (expires_at)',
      target_schema || '_daily_aggregate_expiry_idx',
      target_schema
    );

    execute format('alter table %I.ai_daily_quota enable row level security', target_schema);
    execute format('alter table %I.ai_analysis_requests enable row level security', target_schema);
    execute format('alter table %I.storekit_accounts enable row level security', target_schema);
    execute format('alter table %I.account_entitlements enable row level security', target_schema);
    execute format('alter table %I.storekit_transaction_bindings enable row level security', target_schema);
    execute format('alter table %I.storekit_rebind_markers enable row level security', target_schema);
    execute format('alter table %I.app_store_notification_events enable row level security', target_schema);
    execute format('alter table %I.account_deletion_jobs enable row level security', target_schema);
    execute format('alter table %I.account_deletion_receipts enable row level security', target_schema);
    execute format('alter table %I.operational_events enable row level security', target_schema);
    execute format('alter table %I.daily_operational_aggregates enable row level security', target_schema);

    execute format('revoke all on all tables in schema %I from public, anon, authenticated', target_schema);
    execute format('revoke all on all sequences in schema %I from public, anon, authenticated', target_schema);
  end loop;
end;
$$;

alter default privileges in schema mora_internal revoke all on tables from public, anon, authenticated;
alter default privileges in schema mora_prod_private revoke all on tables from public, anon, authenticated;
alter default privileges in schema mora_stage_private revoke all on tables from public, anon, authenticated;
alter default privileges in schema mora_prod_private revoke all on sequences from public, anon, authenticated;
alter default privileges in schema mora_stage_private revoke all on sequences from public, anon, authenticated;

create or replace function mora_internal.schema_for_environment(p_environment text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select case p_environment
    when 'production' then 'mora_prod_private'
    when 'staging' then 'mora_stage_private'
    else null
  end
$$;

create or replace function mora_internal.is_pro(
  p_schema text,
  p_user_id uuid,
  p_at timestamptz
)
returns boolean
language plpgsql
stable
set search_path = pg_catalog
as $$
declare
  v_is_pro boolean;
begin
  if p_schema not in ('mora_prod_private', 'mora_stage_private') then
    raise exception 'invalid_private_schema' using errcode = '22023';
  end if;

  execute format(
    'select coalesce(status in (''active'', ''grace'') and access_until > $2, false) from %I.account_entitlements where user_id = $1',
    p_schema
  ) into v_is_pro using p_user_id, p_at;

  return coalesce(v_is_pro, false);
end;
$$;

create or replace function mora_internal.quota_json(
  p_schema text,
  p_user_id uuid,
  p_usage_date date,
  p_is_pro boolean
)
returns jsonb
language plpgsql
stable
set search_path = pg_catalog
as $$
declare
  v_successful integer := 0;
  v_reserved integer := 0;
begin
  if p_schema not in ('mora_prod_private', 'mora_stage_private') then
    raise exception 'invalid_private_schema' using errcode = '22023';
  end if;

  execute format(
    'select successful_count, reserved_count from %I.ai_daily_quota where user_id = $1 and usage_date = $2',
    p_schema
  ) into v_successful, v_reserved using p_user_id, p_usage_date;

  v_successful := coalesce(v_successful, 0);
  v_reserved := coalesce(v_reserved, 0);
  return jsonb_build_object(
    'isPro', p_is_pro,
    'limit', case when p_is_pro then null else 3 end,
    'used', v_successful,
    'reserved', v_reserved,
    'remaining', case when p_is_pro then null else greatest(0, 3 - v_successful - v_reserved) end,
    'usageDate', p_usage_date::text,
    'timeZone', 'Asia/Seoul'
  );
end;
$$;

revoke all on function mora_internal.schema_for_environment(text) from public, anon, authenticated;
revoke all on function mora_internal.is_pro(text, uuid, timestamptz) from public, anon, authenticated;
revoke all on function mora_internal.quota_json(text, uuid, date, boolean) from public, anon, authenticated;

create or replace function public.mora_reserve_ai_analysis(
  p_request_id uuid,
  p_input_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_user_id uuid := auth.uid();
  v_environment text;
  v_schema text;
  v_now timestamptz := clock_timestamp();
  v_usage_date date := (clock_timestamp() at time zone 'Asia/Seoul')::date;
  v_status text;
  v_existing_hash text;
  v_existing_date date;
  v_counts boolean;
  v_attempt integer;
  v_expires timestamptz;
  v_retryable boolean;
  v_cached_calls jsonb;
  v_response_expires timestamptz;
  v_is_pro boolean;
  v_successful integer;
  v_reserved integer;
  v_quota jsonb;
begin
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if p_request_id is null or p_input_hash is null or p_input_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_analysis_identity' using errcode = '22023';
  end if;

  v_environment := mora_internal.resolve_environment(v_user_id);
  v_schema := mora_internal.schema_for_environment(v_environment);
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text || ':' || p_request_id::text, 0));

  execute format(
    'select status, input_hash, usage_date, counts_against_quota, attempt_count, reservation_expires_at, retryable, validated_calls, response_expires_at from %I.ai_analysis_requests where user_id = $1 and request_id = $2 for update',
    v_schema
  ) into v_status, v_existing_hash, v_existing_date, v_counts, v_attempt, v_expires,
    v_retryable, v_cached_calls, v_response_expires
    using v_user_id, p_request_id;

  if v_status is not null then
    v_is_pro := mora_internal.is_pro(v_schema, v_user_id, v_now);
    v_quota := mora_internal.quota_json(v_schema, v_user_id, v_existing_date, v_is_pro);

    if v_existing_hash <> p_input_hash then
      return jsonb_build_object('allowed', false, 'reason', 'request_conflict', 'quota', v_quota);
    end if;
    if v_status = 'succeeded' then
      if v_cached_calls is not null and v_response_expires > v_now then
        return jsonb_build_object(
          'allowed', true,
          'reason', null,
          'replay', true,
          'alreadyCommitted', true,
          'cachedCalls', v_cached_calls,
          'quota', v_quota
        );
      end if;
      return jsonb_build_object('allowed', false, 'reason', 'result_expired', 'quota', v_quota);
    end if;

    if v_status = 'reserved' and v_expires > v_now then
      return jsonb_build_object('allowed', false, 'reason', 'in_progress', 'quota', v_quota);
    end if;

    if v_status = 'reserved' then
      if v_counts then
        execute format(
          'update %I.ai_daily_quota set reserved_count = greatest(0, reserved_count - 1), updated_at = $3 where user_id = $1 and usage_date = $2',
          v_schema
        ) using v_user_id, v_existing_date, v_now;
      end if;
      execute format(
        'update %I.ai_analysis_requests set status = ''failed'', completed_at = $3, failure_code = ''reservation_expired'', retryable = true where user_id = $1 and request_id = $2',
        v_schema
      ) using v_user_id, p_request_id, v_now;
      v_status := 'failed';
      v_retryable := true;
    end if;

    if not coalesce(v_retryable, false) then
      return jsonb_build_object('allowed', false, 'reason', 'request_failed', 'quota', v_quota);
    end if;
    if v_attempt >= 3 then
      return jsonb_build_object('allowed', false, 'reason', 'replay_limit', 'quota', v_quota);
    end if;

    execute format(
      'insert into %I.ai_daily_quota (user_id, usage_date) values ($1, $2) on conflict (user_id, usage_date) do nothing',
      v_schema
    ) using v_user_id, v_existing_date;
    execute format(
      'select successful_count, reserved_count from %I.ai_daily_quota where user_id = $1 and usage_date = $2 for update',
      v_schema
    ) into v_successful, v_reserved using v_user_id, v_existing_date;

    v_counts := not v_is_pro;
    if v_counts and v_successful + v_reserved >= 3 then
      v_quota := mora_internal.quota_json(v_schema, v_user_id, v_existing_date, false);
      return jsonb_build_object('allowed', false, 'reason', 'quota_exhausted', 'quota', v_quota);
    end if;
    if v_counts then
      execute format(
        'update %I.ai_daily_quota set reserved_count = reserved_count + 1, updated_at = $3 where user_id = $1 and usage_date = $2',
        v_schema
      ) using v_user_id, v_existing_date, v_now;
    end if;

    execute format(
      'update %I.ai_analysis_requests set status = ''reserved'', counts_against_quota = $3, attempt_count = attempt_count + 1, reserved_at = $4, reservation_expires_at = $5, completed_at = null, failure_code = null, retryable = false, validated_calls = null, response_expires_at = null where user_id = $1 and request_id = $2',
      v_schema
    ) using v_user_id, p_request_id, v_counts, v_now, v_now + interval '5 minutes';

    v_quota := mora_internal.quota_json(v_schema, v_user_id, v_existing_date, v_is_pro);
    return jsonb_build_object(
      'allowed', true,
      'reason', null,
      'replay', true,
      'alreadyCommitted', false,
      'quota', v_quota
    );
  end if;

  v_is_pro := mora_internal.is_pro(v_schema, v_user_id, v_now);
  execute format(
    'insert into %I.ai_daily_quota (user_id, usage_date) values ($1, $2) on conflict (user_id, usage_date) do nothing',
    v_schema
  ) using v_user_id, v_usage_date;
  execute format(
    'select successful_count, reserved_count from %I.ai_daily_quota where user_id = $1 and usage_date = $2 for update',
    v_schema
  ) into v_successful, v_reserved using v_user_id, v_usage_date;

  if not v_is_pro and v_successful + v_reserved >= 3 then
    v_quota := mora_internal.quota_json(v_schema, v_user_id, v_usage_date, false);
    return jsonb_build_object('allowed', false, 'reason', 'quota_exhausted', 'quota', v_quota);
  end if;

  if not v_is_pro then
    execute format(
      'update %I.ai_daily_quota set reserved_count = reserved_count + 1, updated_at = $3 where user_id = $1 and usage_date = $2',
      v_schema
    ) using v_user_id, v_usage_date, v_now;
  end if;

  execute format(
    'insert into %I.ai_analysis_requests (user_id, request_id, usage_date, input_hash, status, counts_against_quota, reservation_expires_at) values ($1, $2, $3, $4, ''reserved'', $5, $6)',
    v_schema
  ) using v_user_id, p_request_id, v_usage_date, p_input_hash, not v_is_pro, v_now + interval '5 minutes';

  v_quota := mora_internal.quota_json(v_schema, v_user_id, v_usage_date, v_is_pro);
  return jsonb_build_object(
    'allowed', true,
    'reason', null,
    'replay', false,
    'alreadyCommitted', false,
    'quota', v_quota
  );
end;
$$;

create or replace function public.mora_finalize_ai_analysis(
  p_request_id uuid,
  p_validated_calls jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_user_id uuid := auth.uid();
  v_schema text;
  v_status text;
  v_usage_date date;
  v_counts boolean;
  v_is_pro boolean;
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if p_validated_calls is null
    or jsonb_typeof(p_validated_calls) <> 'array'
    or jsonb_array_length(p_validated_calls) not between 1 and 50 then
    raise exception 'invalid_validated_calls' using errcode = '22023';
  end if;
  v_schema := mora_internal.schema_for_environment(mora_internal.resolve_environment(v_user_id));
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text || ':' || p_request_id::text, 0));

  execute format(
    'select status, usage_date, counts_against_quota from %I.ai_analysis_requests where user_id = $1 and request_id = $2 for update',
    v_schema
  ) into v_status, v_usage_date, v_counts using v_user_id, p_request_id;

  if v_status is null then
    raise exception 'analysis_request_not_found' using errcode = 'P0002';
  end if;
  if v_status = 'failed' then
    raise exception 'analysis_request_failed' using errcode = 'P0001';
  end if;

  if v_status = 'reserved' then
    if v_counts then
      execute format(
        'update %I.ai_daily_quota set reserved_count = greatest(0, reserved_count - 1), successful_count = successful_count + 1, updated_at = $3 where user_id = $1 and usage_date = $2',
        v_schema
      ) using v_user_id, v_usage_date, v_now;
    end if;
    execute format(
      'update %I.ai_analysis_requests set status = ''succeeded'', completed_at = $3, failure_code = null, retryable = false, validated_calls = $4, response_expires_at = $5 where user_id = $1 and request_id = $2',
      v_schema
    ) using v_user_id, p_request_id, v_now, p_validated_calls, v_now + interval '10 minutes';
  end if;

  v_is_pro := mora_internal.is_pro(v_schema, v_user_id, v_now);
  return mora_internal.quota_json(v_schema, v_user_id, v_usage_date, v_is_pro);
end;
$$;

create or replace function public.mora_fail_ai_analysis(
  p_request_id uuid,
  p_failure_code text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_user_id uuid := auth.uid();
  v_schema text;
  v_status text;
  v_usage_date date;
  v_counts boolean;
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  v_schema := mora_internal.schema_for_environment(mora_internal.resolve_environment(v_user_id));
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text || ':' || p_request_id::text, 0));

  execute format(
    'select status, usage_date, counts_against_quota from %I.ai_analysis_requests where user_id = $1 and request_id = $2 for update',
    v_schema
  ) into v_status, v_usage_date, v_counts using v_user_id, p_request_id;

  if v_status is null then
    return jsonb_build_object('status', 'missing');
  end if;
  if v_status = 'succeeded' then
    return jsonb_build_object('status', 'succeeded');
  end if;
  if v_status = 'reserved' and v_counts then
    execute format(
      'update %I.ai_daily_quota set reserved_count = greatest(0, reserved_count - 1), updated_at = $3 where user_id = $1 and usage_date = $2',
      v_schema
    ) using v_user_id, v_usage_date, v_now;
  end if;
  if v_status = 'reserved' then
    execute format(
      'update %I.ai_analysis_requests set status = ''failed'', completed_at = $3, failure_code = $4, retryable = $5, validated_calls = null, response_expires_at = null where user_id = $1 and request_id = $2',
      v_schema
    ) using v_user_id, p_request_id, v_now,
      left(regexp_replace(coalesce(p_failure_code, 'analysis_failed'), '[^a-zA-Z0-9_.-]', '_', 'g'), 64),
      coalesce(p_failure_code, 'analysis_failed') in (
        'analysis_failed',
        'gemini_network_failed',
        'gemini_request_failed',
        'quota_finalize_failed'
      );
  end if;
  return jsonb_build_object('status', 'failed');
end;
$$;

create or replace function public.mora_get_entitlement()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_user_id uuid := auth.uid();
  v_schema text;
  v_status text;
  v_product_id text;
  v_verified_at timestamptz;
  v_expires_at timestamptz;
  v_grace_expires_at timestamptz;
  v_access_until timestamptz;
begin
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  v_schema := mora_internal.schema_for_environment(mora_internal.resolve_environment(v_user_id));
  execute format(
    'select status, product_id, verified_at, expires_at, grace_expires_at, access_until from %I.account_entitlements where user_id = $1',
    v_schema
  ) into v_status, v_product_id, v_verified_at, v_expires_at, v_grace_expires_at, v_access_until
    using v_user_id;

  v_status := coalesce(v_status, 'none');
  return jsonb_build_object(
    'isPro', v_status in ('active', 'grace') and v_access_until > clock_timestamp(),
    'status', v_status,
    'productId', v_product_id,
    'verifiedAt', v_verified_at,
    'expiresAt', v_expires_at,
    'graceExpiresAt', v_grace_expires_at,
    'accessUntil', v_access_until
  );
end;
$$;

create or replace function public.mora_get_app_account_token()
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_user_id uuid := auth.uid();
  v_schema text;
  v_token uuid;
begin
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  v_schema := mora_internal.schema_for_environment(mora_internal.resolve_environment(v_user_id));
  execute format(
    'insert into %I.storekit_accounts (user_id) values ($1) on conflict (user_id) do update set updated_at = clock_timestamp() returning app_account_token',
    v_schema
  ) into v_token using v_user_id;
  return v_token;
end;
$$;

create or replace function public.mora_record_operational_event(
  p_request_id uuid,
  p_event_name text,
  p_status_code integer,
  p_duration_ms integer default null,
  p_input_length integer default null,
  p_output_count integer default null,
  p_failure_code text default null
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_user_id uuid := auth.uid();
  v_schema text;
  v_failure_code text;
begin
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if p_event_name not in ('analysis_succeeded', 'analysis_failed', 'quota_denied') then
    raise exception 'invalid_event_name' using errcode = '22023';
  end if;
  v_failure_code := case when p_failure_code is null then null else
    left(regexp_replace(p_failure_code, '[^a-zA-Z0-9_.-]', '_', 'g'), 64) end;
  v_schema := mora_internal.schema_for_environment(mora_internal.resolve_environment(v_user_id));
  execute format(
    'insert into %I.operational_events (user_id, request_id, event_name, status_code, duration_ms, input_length, output_count, failure_code) values ($1, $2, $3, $4, $5, $6, $7, $8) on conflict (user_id, request_id, event_name) do nothing',
    v_schema
  ) using v_user_id, p_request_id, p_event_name, p_status_code,
    p_duration_ms, p_input_length, p_output_count, v_failure_code;
end;
$$;

revoke all on function public.mora_reserve_ai_analysis(uuid, text) from public, anon;
revoke all on function public.mora_finalize_ai_analysis(uuid, jsonb) from public, anon;
revoke all on function public.mora_fail_ai_analysis(uuid, text) from public, anon;
revoke all on function public.mora_get_entitlement() from public, anon;
revoke all on function public.mora_get_app_account_token() from public, anon;
revoke all on function public.mora_record_operational_event(uuid, text, integer, integer, integer, integer, text) from public, anon;

grant execute on function public.mora_reserve_ai_analysis(uuid, text) to authenticated;
grant execute on function public.mora_finalize_ai_analysis(uuid, jsonb) to authenticated;
grant execute on function public.mora_fail_ai_analysis(uuid, text) to authenticated;
grant execute on function public.mora_get_entitlement() to authenticated;
grant execute on function public.mora_get_app_account_token() to authenticated;
grant execute on function public.mora_record_operational_event(uuid, text, integer, integer, integer, integer, text) to authenticated;

create or replace function mora_internal.require_service_role()
returns void
language plpgsql
stable
set search_path = pg_catalog, auth
as $$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
end;
$$;

create or replace function mora_internal.deletion_environment(p_user_id uuid)
returns text
language plpgsql
set search_path = pg_catalog, auth, mora_internal
as $$
declare
  v_environment text;
begin
  select environment
    into v_environment
    from mora_internal.account_environment
   where user_id = p_user_id;

  if v_environment is null then
    select coalesce(raw_app_meta_data ->> 'mora_environment', 'production')
      into v_environment
      from auth.users
     where id = p_user_id;
    if not found then
      raise exception 'deletion_user_not_found' using errcode = 'P0002';
    end if;
    if v_environment not in ('production', 'staging') then
      raise exception 'invalid_environment_claim' using errcode = '22023';
    end if;
    insert into mora_internal.account_environment (user_id, environment)
    values (p_user_id, v_environment)
    on conflict (user_id) do nothing;
  end if;

  if v_environment not in ('production', 'staging') then
    raise exception 'invalid_environment_binding' using errcode = '22023';
  end if;
  return v_environment;
end;
$$;

create or replace function mora_internal.deletion_schema_for_secret(
  p_request_id uuid,
  p_status_token_hash text
)
returns text
language plpgsql
stable
set search_path = pg_catalog
as $$
declare
  v_schema text;
  v_found boolean;
begin
  if p_request_id is null
    or p_status_token_hash is null
    or p_status_token_hash !~ '^[0-9a-f]{64}$' then
    return null;
  end if;
  foreach v_schema in array array['mora_prod_private', 'mora_stage_private']
  loop
    execute format(
      'select exists (select 1 from %I.account_deletion_jobs where idempotency_key = $1 and status_token_hash = $2)',
      v_schema
    ) into v_found using p_request_id, p_status_token_hash;
    if v_found then
      return v_schema;
    end if;
  end loop;
  return null;
end;
$$;

create or replace function mora_internal.deletion_job_json(
  p_schema text,
  p_request_id uuid,
  p_status_token_hash text
)
returns jsonb
language plpgsql
stable
set search_path = pg_catalog
as $$
declare
  v_result jsonb;
begin
  if p_schema not in ('mora_prod_private', 'mora_stage_private') then
    raise exception 'invalid_private_schema' using errcode = '22023';
  end if;
  execute format($sql$
    select jsonb_build_object(
      'jobId', job_id,
      'requestId', idempotency_key,
      'status', status,
      'userId', user_id,
      'environment', environment,
      'appleRevokedAt', apple_revoked_at,
      'dataPurgedAt', data_purged_at,
      'authDeletedAt', auth_deleted_at,
      'nextAttemptAt', next_attempt_at,
      'leaseExpiresAt', lease_expires_at,
      'requiresAppleReauth', requires_apple_reauth,
      'attemptCount', attempt_count
    )
    from %I.account_deletion_jobs
    where idempotency_key = $1 and status_token_hash = $2
  $sql$, p_schema) into v_result using p_request_id, p_status_token_hash;
  return v_result;
end;
$$;

revoke all on function mora_internal.require_service_role() from public, anon, authenticated;
revoke all on function mora_internal.deletion_environment(uuid) from public, anon, authenticated;
revoke all on function mora_internal.deletion_schema_for_secret(uuid, text) from public, anon, authenticated;
revoke all on function mora_internal.deletion_job_json(text, uuid, text) from public, anon, authenticated;

create or replace function public.mora_begin_account_deletion(
  p_user_id uuid,
  p_request_id uuid,
  p_status_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_environment text;
  v_schema text;
  v_job_id uuid;
  v_existing_request uuid;
  v_lock_job_id uuid;
begin
  perform mora_internal.require_service_role();
  if p_user_id is null or p_request_id is null
    or p_status_token_hash is null
    or p_status_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_deletion_request' using errcode = '22023';
  end if;

  v_environment := mora_internal.deletion_environment(p_user_id);
  v_schema := mora_internal.schema_for_environment(v_environment);
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:' || p_user_id::text, 0));

  execute format($sql$
    select job_id, idempotency_key
      from %I.account_deletion_jobs
     where user_id = $1
       and status in ('requested', 'running', 'retry_wait')
     order by accepted_at
     limit 1
     for update
  $sql$, v_schema) into v_job_id, v_existing_request using p_user_id;

  if v_job_id is not null and v_existing_request is distinct from p_request_id then
    raise exception 'account_deletion_already_pending' using errcode = '23505';
  end if;

  if v_job_id is null then
    execute format($sql$
      insert into %I.account_deletion_jobs (
        user_id, idempotency_key, environment, status_token_hash
      ) values ($1, $2, $3, $4)
      returning job_id
    $sql$, v_schema) into v_job_id
      using p_user_id, p_request_id, v_environment, p_status_token_hash;
  else
    execute format($sql$
      update %I.account_deletion_jobs
         set status_token_hash = $3,
             updated_at = clock_timestamp()
       where user_id = $1 and idempotency_key = $2
    $sql$, v_schema) using p_user_id, p_request_id, p_status_token_hash;
  end if;

  select job_id
    into v_lock_job_id
    from mora_internal.account_deletion_locks
   where user_id = p_user_id
   for update;
  if v_lock_job_id is not null and v_lock_job_id is distinct from v_job_id then
    raise exception 'account_deletion_lock_conflict' using errcode = '23505';
  end if;
  insert into mora_internal.account_deletion_locks (user_id, job_id, environment)
  values (p_user_id, v_job_id, v_environment)
  on conflict (user_id) do nothing;

  return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
end;
$$;

create or replace function public.mora_get_account_deletion_status(
  p_request_id uuid,
  p_status_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_schema text;
begin
  perform mora_internal.require_service_role();
  v_schema := mora_internal.deletion_schema_for_secret(p_request_id, p_status_token_hash);
  if v_schema is null then
    return null;
  end if;
  return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
end;
$$;

create or replace function public.mora_claim_account_deletion(
  p_request_id uuid,
  p_status_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_schema text;
  v_status text;
  v_lease_expires_at timestamptz;
  v_next_attempt_at timestamptz;
  v_result jsonb;
begin
  perform mora_internal.require_service_role();
  v_schema := mora_internal.deletion_schema_for_secret(p_request_id, p_status_token_hash);
  if v_schema is null then
    return null;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:' || p_request_id::text, 0));
  execute format($sql$
    select status, lease_expires_at, next_attempt_at
      from %I.account_deletion_jobs
     where idempotency_key = $1 and status_token_hash = $2
     for update
  $sql$, v_schema) into v_status, v_lease_expires_at, v_next_attempt_at
    using p_request_id, p_status_token_hash;

  if v_status in ('completed', 'failed') then
    return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash)
      || jsonb_build_object('claimed', false, 'reason', 'terminal');
  end if;
  if v_status = 'running' and v_lease_expires_at > clock_timestamp() then
    return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash)
      || jsonb_build_object('claimed', false, 'reason', 'in_progress');
  end if;
  if v_status = 'retry_wait' and v_next_attempt_at > clock_timestamp() then
    return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash)
      || jsonb_build_object('claimed', false, 'reason', 'retry_wait');
  end if;

  execute format($sql$
    update %I.account_deletion_jobs
       set status = 'running',
           attempt_count = attempt_count + 1,
           lease_expires_at = clock_timestamp() + interval '2 minutes',
           next_attempt_at = null,
           updated_at = clock_timestamp()
     where idempotency_key = $1 and status_token_hash = $2
  $sql$, v_schema) using p_request_id, p_status_token_hash;
  v_result := mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
  return v_result || jsonb_build_object('claimed', true, 'reason', null);
end;
$$;

create or replace function public.mora_mark_account_deletion_apple_revoked(
  p_request_id uuid,
  p_status_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_schema text;
begin
  perform mora_internal.require_service_role();
  v_schema := mora_internal.deletion_schema_for_secret(p_request_id, p_status_token_hash);
  if v_schema is null then
    return null;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:' || p_request_id::text, 0));
  execute format($sql$
    update %I.account_deletion_jobs
       set apple_revoked_at = coalesce(apple_revoked_at, clock_timestamp()),
           requires_apple_reauth = false,
           failure_code = null,
           lease_expires_at = clock_timestamp() + interval '2 minutes',
           updated_at = clock_timestamp()
     where idempotency_key = $1
       and status_token_hash = $2
       and status = 'running'
  $sql$, v_schema) using p_request_id, p_status_token_hash;
  return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
end;
$$;

create or replace function public.mora_purge_account_deletion_data(
  p_request_id uuid,
  p_status_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_schema text;
  v_job_id uuid;
  v_user_id uuid;
  v_account_marker text;
  v_status text;
  v_apple_revoked_at timestamptz;
  v_data_purged_at timestamptz;
begin
  perform mora_internal.require_service_role();
  v_schema := mora_internal.deletion_schema_for_secret(p_request_id, p_status_token_hash);
  if v_schema is null then
    return null;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:' || p_request_id::text, 0));
  execute format($sql$
    select job_id, user_id, account_marker, status, apple_revoked_at, data_purged_at
      from %I.account_deletion_jobs
     where idempotency_key = $1 and status_token_hash = $2
     for update
  $sql$, v_schema) into v_job_id, v_user_id, v_account_marker, v_status,
    v_apple_revoked_at, v_data_purged_at using p_request_id, p_status_token_hash;

  if v_data_purged_at is not null then
    return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
  end if;
  if v_status <> 'running' or v_apple_revoked_at is null or v_user_id is null then
    raise exception 'deletion_not_ready_for_purge' using errcode = '55000';
  end if;

  execute format($sql$
    insert into %I.storekit_rebind_markers (
      apple_environment, original_transaction_id, deleted_account_marker,
      deletion_job_id, eligible_at, consumed_by_user_id, consumed_at, retain_until
    )
    select
      apple_environment,
      original_transaction_id,
      $1,
      $2,
      clock_timestamp(),
      null,
      null,
      least(
        greatest(
          clock_timestamp() + interval '30 days',
          coalesce(grace_expires_at, expires_at, clock_timestamp()) + interval '30 days'
        ),
        clock_timestamp() + interval '400 days'
      )
      from %I.storekit_transaction_bindings
     where user_id = $3
       and state in ('active', 'grace', 'billing_retry')
    on conflict (apple_environment, original_transaction_id) do update set
      deleted_account_marker = excluded.deleted_account_marker,
      deletion_job_id = excluded.deletion_job_id,
      eligible_at = excluded.eligible_at,
      consumed_by_user_id = null,
      consumed_at = null,
      retain_until = excluded.retain_until
  $sql$, v_schema, v_schema) using v_account_marker, v_job_id, v_user_id;

  execute format(
    'delete from %I.storekit_rebind_markers where consumed_by_user_id = $1',
    v_schema
  ) using v_user_id;
  execute format(
    'update %I.storekit_transaction_bindings set user_id = null, app_account_token = null, updated_at = clock_timestamp() where user_id = $1',
    v_schema
  ) using v_user_id;
  execute format('delete from %I.ai_analysis_requests where user_id = $1', v_schema) using v_user_id;
  execute format('delete from %I.ai_daily_quota where user_id = $1', v_schema) using v_user_id;
  execute format('delete from %I.account_entitlements where user_id = $1', v_schema) using v_user_id;
  execute format('delete from %I.storekit_accounts where user_id = $1', v_schema) using v_user_id;
  execute format('delete from %I.operational_events where user_id = $1', v_schema) using v_user_id;
  delete from mora_internal.account_environment where user_id = v_user_id;

  execute format($sql$
    update %I.account_deletion_jobs
       set data_purged_at = clock_timestamp(),
           lease_expires_at = clock_timestamp() + interval '2 minutes',
           updated_at = clock_timestamp()
     where job_id = $1
  $sql$, v_schema) using v_job_id;
  return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
end;
$$;

create or replace function public.mora_mark_account_deletion_retry(
  p_request_id uuid,
  p_status_token_hash text,
  p_failure_code text,
  p_requires_apple_reauth boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_schema text;
  v_status text;
  v_attempt_count integer;
  v_delay_seconds integer;
  v_failure_code text;
begin
  perform mora_internal.require_service_role();
  v_schema := mora_internal.deletion_schema_for_secret(p_request_id, p_status_token_hash);
  if v_schema is null then
    return null;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:' || p_request_id::text, 0));
  execute format($sql$
    select status, attempt_count
      from %I.account_deletion_jobs
     where idempotency_key = $1 and status_token_hash = $2
     for update
  $sql$, v_schema) into v_status, v_attempt_count using p_request_id, p_status_token_hash;
  if v_status in ('completed', 'failed') then
    return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
  end if;

  v_failure_code := left(
    regexp_replace(coalesce(p_failure_code, 'deletion_failed'), '[^a-zA-Z0-9_.-]', '_', 'g'),
    64
  );
  v_delay_seconds := case
    when coalesce(p_requires_apple_reauth, false) then 0
    else least(900, 5 * (2 ^ least(coalesce(v_attempt_count, 1), 8)))
  end;
  execute format($sql$
    update %I.account_deletion_jobs
       set status = 'retry_wait',
           next_attempt_at = clock_timestamp() + make_interval(secs => $3),
           lease_expires_at = null,
           failure_code = $4,
           requires_apple_reauth = $5,
           updated_at = clock_timestamp()
     where idempotency_key = $1 and status_token_hash = $2
  $sql$, v_schema) using p_request_id, p_status_token_hash, v_delay_seconds,
    v_failure_code, coalesce(p_requires_apple_reauth, false);
  return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
end;
$$;

create or replace function public.mora_complete_account_deletion(
  p_request_id uuid,
  p_status_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_schema text;
  v_job_id uuid;
  v_user_id uuid;
  v_account_marker text;
  v_status text;
  v_data_purged_at timestamptz;
  v_completed_at timestamptz := clock_timestamp();
begin
  perform mora_internal.require_service_role();
  v_schema := mora_internal.deletion_schema_for_secret(p_request_id, p_status_token_hash);
  if v_schema is null then
    return null;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('account-deletion:' || p_request_id::text, 0));
  execute format($sql$
    select job_id, user_id, account_marker, status, data_purged_at
      from %I.account_deletion_jobs
     where idempotency_key = $1 and status_token_hash = $2
     for update
  $sql$, v_schema) into v_job_id, v_user_id, v_account_marker, v_status,
    v_data_purged_at using p_request_id, p_status_token_hash;
  if v_status = 'completed' then
    return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
  end if;
  if v_data_purged_at is null or v_user_id is null then
    raise exception 'deletion_not_ready_for_completion' using errcode = '55000';
  end if;
  if exists (select 1 from auth.users where id = v_user_id) then
    raise exception 'auth_user_still_exists' using errcode = '55000';
  end if;

  execute format($sql$
    update %I.account_deletion_jobs
       set user_id = null,
           status = 'completed',
           auth_deleted_at = coalesce(auth_deleted_at, $2),
           completed_at = coalesce(completed_at, $2),
           next_attempt_at = null,
           lease_expires_at = null,
           failure_code = null,
           requires_apple_reauth = false,
           updated_at = $2
     where job_id = $1
  $sql$, v_schema) using v_job_id, v_completed_at;
  delete from mora_internal.account_deletion_locks where user_id = v_user_id;
  execute format($sql$
    insert into %I.account_deletion_receipts (
      job_id, account_marker, completed_at, expires_at
    ) values ($1, $2, $3, $3 + interval '30 days')
    on conflict (job_id) do update set
      account_marker = excluded.account_marker,
      completed_at = excluded.completed_at,
      expires_at = excluded.expires_at
  $sql$, v_schema) using v_job_id, v_account_marker, v_completed_at;
  return mora_internal.deletion_job_json(v_schema, p_request_id, p_status_token_hash);
end;
$$;

revoke all on function public.mora_begin_account_deletion(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.mora_get_account_deletion_status(uuid, text) from public, anon, authenticated;
revoke all on function public.mora_claim_account_deletion(uuid, text) from public, anon, authenticated;
revoke all on function public.mora_mark_account_deletion_apple_revoked(uuid, text) from public, anon, authenticated;
revoke all on function public.mora_purge_account_deletion_data(uuid, text) from public, anon, authenticated;
revoke all on function public.mora_mark_account_deletion_retry(uuid, text, text, boolean) from public, anon, authenticated;
revoke all on function public.mora_complete_account_deletion(uuid, text) from public, anon, authenticated;

grant execute on function public.mora_begin_account_deletion(uuid, uuid, text) to service_role;
grant execute on function public.mora_get_account_deletion_status(uuid, text) to service_role;
grant execute on function public.mora_claim_account_deletion(uuid, text) to service_role;
grant execute on function public.mora_mark_account_deletion_apple_revoked(uuid, text) to service_role;
grant execute on function public.mora_purge_account_deletion_data(uuid, text) to service_role;
grant execute on function public.mora_mark_account_deletion_retry(uuid, text, text, boolean) to service_role;
grant execute on function public.mora_complete_account_deletion(uuid, text) to service_role;

create or replace function mora_internal.cleanup_schema(p_schema text, p_batch_size integer)
returns jsonb
language plpgsql
set search_path = pg_catalog
as $$
declare
  v_expired_reservations integer := 0;
  v_events_deleted integer := 0;
  v_aggregates_deleted integer := 0;
  v_receipts_deleted integer := 0;
  v_rebind_deleted integer := 0;
  v_ai_requests_deleted integer := 0;
  v_ai_days_deleted integer := 0;
  v_store_events_deleted integer := 0;
  v_cached_responses_cleared integer := 0;
  stale record;
begin
  if p_schema not in ('mora_prod_private', 'mora_stage_private') then
    raise exception 'invalid_private_schema' using errcode = '22023';
  end if;

  for stale in execute format(
    'select user_id, request_id, usage_date, counts_against_quota from %I.ai_analysis_requests where status = ''reserved'' and reservation_expires_at <= clock_timestamp() order by reservation_expires_at limit $1 for update skip locked',
    p_schema
  ) using p_batch_size
  loop
    if stale.counts_against_quota then
      execute format(
        'update %I.ai_daily_quota set reserved_count = greatest(0, reserved_count - 1), updated_at = clock_timestamp() where user_id = $1 and usage_date = $2',
        p_schema
      ) using stale.user_id, stale.usage_date;
    end if;
    execute format(
      'update %I.ai_analysis_requests set status = ''failed'', completed_at = clock_timestamp(), failure_code = ''reservation_expired'', retryable = true where user_id = $1 and request_id = $2 and status = ''reserved''',
      p_schema
    ) using stale.user_id, stale.request_id;
    v_expired_reservations := v_expired_reservations + 1;
  end loop;

  execute format($sql$
    insert into %I.daily_operational_aggregates (
      metric_date, event_name, status_class, event_count,
      total_duration_ms, max_duration_ms, expires_at
    )
    select
      (occurred_at at time zone 'Asia/Seoul')::date,
      event_name,
      (status_code / 100)::text || 'xx',
      count(*),
      coalesce(sum(duration_ms), 0),
      coalesce(max(duration_ms), 0),
      ((occurred_at at time zone 'Asia/Seoul')::date + interval '90 days') at time zone 'Asia/Seoul'
    from %I.operational_events
    where (occurred_at at time zone 'Asia/Seoul')::date < (clock_timestamp() at time zone 'Asia/Seoul')::date
    group by 1, 2, 3
    on conflict (metric_date, event_name, status_class) do update set
      event_count = excluded.event_count,
      total_duration_ms = excluded.total_duration_ms,
      max_duration_ms = excluded.max_duration_ms,
      updated_at = clock_timestamp(),
      expires_at = excluded.expires_at
  $sql$, p_schema, p_schema);

  execute format(
    'delete from %I.operational_events where event_id in (select event_id from %I.operational_events where expires_at <= clock_timestamp() order by expires_at, event_id limit $1)',
    p_schema,
    p_schema
  ) using p_batch_size;
  get diagnostics v_events_deleted = row_count;

  execute format(
    'delete from %I.daily_operational_aggregates where (metric_date, event_name, status_class) in (select metric_date, event_name, status_class from %I.daily_operational_aggregates where expires_at <= clock_timestamp() order by expires_at limit $1)',
    p_schema,
    p_schema
  ) using p_batch_size;
  get diagnostics v_aggregates_deleted = row_count;

  execute format(
    'delete from %I.account_deletion_receipts where job_id in (select job_id from %I.account_deletion_receipts where expires_at <= clock_timestamp() order by expires_at limit $1)',
    p_schema,
    p_schema
  ) using p_batch_size;
  get diagnostics v_receipts_deleted = row_count;

  execute format(
    'delete from %I.storekit_rebind_markers where (apple_environment, original_transaction_id) in (select apple_environment, original_transaction_id from %I.storekit_rebind_markers where retain_until <= clock_timestamp() order by retain_until limit $1)',
    p_schema,
    p_schema
  ) using p_batch_size;
  get diagnostics v_rebind_deleted = row_count;

  execute format(
    'update %I.ai_analysis_requests set validated_calls = null, response_expires_at = null where (user_id, request_id) in (select user_id, request_id from %I.ai_analysis_requests where validated_calls is not null and response_expires_at <= clock_timestamp() order by response_expires_at limit $1)',
    p_schema,
    p_schema
  ) using p_batch_size;
  get diagnostics v_cached_responses_cleared = row_count;

  execute format(
    'delete from %I.ai_analysis_requests where (user_id, request_id) in (select user_id, request_id from %I.ai_analysis_requests where status in (''succeeded'', ''failed'') and completed_at <= clock_timestamp() - interval ''14 days'' order by completed_at limit $1)',
    p_schema,
    p_schema
  ) using p_batch_size;
  get diagnostics v_ai_requests_deleted = row_count;

  execute format(
    'delete from %I.ai_daily_quota where (user_id, usage_date) in (select q.user_id, q.usage_date from %I.ai_daily_quota q where q.usage_date < (clock_timestamp() at time zone ''Asia/Seoul'')::date - 14 and not exists (select 1 from %I.ai_analysis_requests r where r.user_id = q.user_id and r.usage_date = q.usage_date) order by q.usage_date limit $1)',
    p_schema,
    p_schema,
    p_schema
  ) using p_batch_size;
  get diagnostics v_ai_days_deleted = row_count;

  execute format(
    'delete from %I.app_store_notification_events where notification_uuid in (select notification_uuid from %I.app_store_notification_events where expires_at <= clock_timestamp() order by expires_at limit $1)',
    p_schema,
    p_schema
  ) using p_batch_size;
  get diagnostics v_store_events_deleted = row_count;

  execute format(
    'delete from %I.account_deletion_jobs where job_id in (select job_id from %I.account_deletion_jobs j where status = ''completed'' and completed_at <= clock_timestamp() - interval ''30 days'' and not exists (select 1 from %I.account_deletion_receipts r where r.job_id = j.job_id) order by completed_at limit $1)',
    p_schema,
    p_schema,
    p_schema
  ) using p_batch_size;

  return jsonb_build_object(
    'expiredReservations', v_expired_reservations,
    'eventsDeleted', v_events_deleted,
    'aggregatesDeleted', v_aggregates_deleted,
    'receiptsDeleted', v_receipts_deleted,
    'rebindMarkersDeleted', v_rebind_deleted,
    'aiRequestsDeleted', v_ai_requests_deleted,
    'aiDaysDeleted', v_ai_days_deleted,
    'storeEventsDeleted', v_store_events_deleted,
    'cachedResponsesCleared', v_cached_responses_cleared
  );
end;
$$;

revoke all on function mora_internal.cleanup_schema(text, integer) from public, anon, authenticated;

create or replace function public.mora_cleanup_security_data(p_batch_size integer default 500)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal
as $$
declare
  v_batch integer := least(greatest(coalesce(p_batch_size, 500), 1), 5000);
  v_role text := coalesce(auth.jwt() ->> 'role', '');
begin
  if v_role <> 'service_role' and session_user <> 'postgres' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'production', mora_internal.cleanup_schema('mora_prod_private', v_batch),
    'staging', mora_internal.cleanup_schema('mora_stage_private', v_batch),
    'batchSizePerEnvironment', v_batch
  );
end;
$$;

revoke all on function public.mora_cleanup_security_data(integer) from public, anon, authenticated;
grant execute on function public.mora_cleanup_security_data(integer) to service_role;
