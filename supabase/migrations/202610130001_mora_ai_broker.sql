-- AI quota mutations and operational events belong to the verified Edge broker.
-- Apply together with analyze-task v2: old clients cannot invoke the ledger directly.
-- get_adult_eligibility binds the account environment before the Edge calls v2.
begin;

create table if not exists mora_internal.ai_request_windows (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_started_at timestamptz not null,
  request_count integer not null check (request_count between 1 and 30)
);
alter table mora_internal.ai_request_windows enable row level security;
revoke all on mora_internal.ai_request_windows from public, anon, authenticated, service_role;


create or replace function public.mora_reserve_ai_analysis_v2(
  p_user_id uuid,
  p_request_id uuid,
  p_input_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_user_id uuid := p_user_id;
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
  v_request_count integer;
begin
  perform mora_internal.require_service_role();
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if p_request_id is null or p_input_hash is null or p_input_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_analysis_identity' using errcode = '22023';
  end if;

  v_schema := mora_internal.storekit_account_schema(v_user_id);
  -- One atomic counter per account across all Edge instances, including failures
  -- and paid plans. Client retries count too; this is separate from daily quota.
  insert into mora_internal.ai_request_windows as w (user_id, window_started_at, request_count)
  values (v_user_id, v_now, 1)
  on conflict (user_id) do update set
    window_started_at = case when w.window_started_at <= v_now - interval '1 minute' then v_now else w.window_started_at end,
    request_count = case when w.window_started_at <= v_now - interval '1 minute' then 1 else w.request_count + 1 end
  where w.window_started_at <= v_now - interval '1 minute' or w.request_count < 30
  returning request_count into v_request_count;
  if v_request_count is null then
    return jsonb_build_object('allowed', false, 'reason', 'rate_limited');
  end if;
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

revoke all on function public.mora_reserve_ai_analysis(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.mora_reserve_ai_analysis_v2(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.mora_reserve_ai_analysis_v2(uuid, uuid, text) to service_role;

create or replace function public.mora_finalize_ai_analysis_v2(
  p_user_id uuid,
  p_request_id uuid,
  p_validated_calls jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_user_id uuid := p_user_id;
  v_schema text;
  v_status text;
  v_usage_date date;
  v_counts boolean;
  v_is_pro boolean;
  v_now timestamptz := clock_timestamp();
begin
  perform mora_internal.require_service_role();
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if p_validated_calls is null
    or jsonb_typeof(p_validated_calls) <> 'array'
    or jsonb_array_length(p_validated_calls) not between 1 and 50 then
    raise exception 'invalid_validated_calls' using errcode = '22023';
  end if;
  v_schema := mora_internal.storekit_account_schema(v_user_id);
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

revoke all on function public.mora_finalize_ai_analysis(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.mora_finalize_ai_analysis_v2(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.mora_finalize_ai_analysis_v2(uuid, uuid, jsonb) to service_role;

create or replace function public.mora_fail_ai_analysis_v2(
  p_user_id uuid,
  p_request_id uuid,
  p_failure_code text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_user_id uuid := p_user_id;
  v_schema text;
  v_status text;
  v_usage_date date;
  v_counts boolean;
  v_now timestamptz := clock_timestamp();
begin
  perform mora_internal.require_service_role();
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  v_schema := mora_internal.storekit_account_schema(v_user_id);
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
        'model_providers_unavailable',
        'gemini_network_failed',
        'gemini_request_failed',
        'quota_finalize_failed'
      );
  end if;
  return jsonb_build_object('status', 'failed');
end;
$$;

revoke all on function public.mora_fail_ai_analysis(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.mora_fail_ai_analysis_v2(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.mora_fail_ai_analysis_v2(uuid, uuid, text) to service_role;

create or replace function public.mora_record_operational_event_v2(
  p_user_id uuid,
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
  v_user_id uuid := p_user_id;
  v_schema text;
  v_failure_code text;
begin
  perform mora_internal.require_service_role();
  if v_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if p_event_name not in ('analysis_succeeded', 'analysis_failed', 'quota_denied') then
    raise exception 'invalid_event_name' using errcode = '22023';
  end if;
  v_failure_code := case when p_failure_code is null then null else
    left(regexp_replace(p_failure_code, '[^a-zA-Z0-9_.-]', '_', 'g'), 64) end;
  v_schema := mora_internal.storekit_account_schema(v_user_id);
  execute format(
    'insert into %I.operational_events (user_id, request_id, event_name, status_code, duration_ms, input_length, output_count, failure_code) values ($1, $2, $3, $4, $5, $6, $7, $8) on conflict (user_id, request_id, event_name) do nothing',
    v_schema
  ) using v_user_id, p_request_id, p_event_name, p_status_code,
    p_duration_ms, p_input_length, p_output_count, v_failure_code;
end;
$$;

revoke all on function public.mora_record_operational_event(uuid, text, integer, integer, integer, integer, text) from public, anon, authenticated, service_role;
revoke all on function public.mora_record_operational_event_v2(uuid, uuid, text, integer, integer, integer, integer, text) from public, anon, authenticated;
grant execute on function public.mora_record_operational_event_v2(uuid, uuid, text, integer, integer, integer, integer, text) to service_role;

commit;
