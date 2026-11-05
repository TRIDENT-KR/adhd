-- Free AI analyses go from 3 to 5 a day, but only for apps that ask for it.
-- Older apps reject any quota snapshot whose limit is not exactly 3, so analyze-task
-- passes p_free_limit = 5 only when the request body says freeDailyLimit = "5".
-- The 3-argument versions stay (now wrappers passing 3), so the analyze-task deployed
-- before this migration keeps working. No defaults: an overload with a default would make
-- 3-argument calls ambiguous.
begin;

create or replace function mora_internal.quota_json(
  p_schema text,
  p_user_id uuid,
  p_usage_date date,
  p_is_pro boolean,
  p_free_limit integer
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
  if p_free_limit is null or p_free_limit not in (3, 5) then
    raise exception 'invalid_free_limit' using errcode = '22023';
  end if;
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
    'limit', case when p_is_pro then null else p_free_limit end,
    'used', v_successful,
    'reserved', v_reserved,
    'remaining', case when p_is_pro then null else greatest(0, p_free_limit - v_successful - v_reserved) end,
    'usageDate', p_usage_date::text,
    'timeZone', 'Asia/Seoul'
  );
end;
$$;

revoke all on function mora_internal.quota_json(text, uuid, date, boolean, integer) from public, anon, authenticated;

create or replace function public.mora_reserve_ai_analysis_v2(
  p_user_id uuid,
  p_request_id uuid,
  p_input_hash text,
  p_free_limit integer
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
  if p_free_limit is null or p_free_limit not in (3, 5) then
    raise exception 'invalid_free_limit' using errcode = '22023';
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
    v_quota := mora_internal.quota_json(v_schema, v_user_id, v_existing_date, v_is_pro, p_free_limit);

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
    if v_counts and v_successful + v_reserved >= p_free_limit then
      v_quota := mora_internal.quota_json(v_schema, v_user_id, v_existing_date, false, p_free_limit);
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

    v_quota := mora_internal.quota_json(v_schema, v_user_id, v_existing_date, v_is_pro, p_free_limit);
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

  if not v_is_pro and v_successful + v_reserved >= p_free_limit then
    v_quota := mora_internal.quota_json(v_schema, v_user_id, v_usage_date, false, p_free_limit);
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

  v_quota := mora_internal.quota_json(v_schema, v_user_id, v_usage_date, v_is_pro, p_free_limit);
  return jsonb_build_object(
    'allowed', true,
    'reason', null,
    'replay', false,
    'alreadyCommitted', false,
    'quota', v_quota
  );
end;
$$;

revoke all on function public.mora_reserve_ai_analysis_v2(uuid, uuid, text, integer) from public, anon, authenticated;
grant execute on function public.mora_reserve_ai_analysis_v2(uuid, uuid, text, integer) to service_role;

create or replace function public.mora_finalize_ai_analysis_v2(
  p_user_id uuid,
  p_request_id uuid,
  p_validated_calls jsonb,
  p_free_limit integer
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
  return mora_internal.quota_json(v_schema, v_user_id, v_usage_date, v_is_pro, p_free_limit);
end;
$$;

revoke all on function public.mora_finalize_ai_analysis_v2(uuid, uuid, jsonb, integer) from public, anon, authenticated;
grant execute on function public.mora_finalize_ai_analysis_v2(uuid, uuid, jsonb, integer) to service_role;

create or replace function public.mora_reserve_ai_analysis_v2(
  p_user_id uuid,
  p_request_id uuid,
  p_input_hash text
)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select public.mora_reserve_ai_analysis_v2(p_user_id, p_request_id, p_input_hash, 3);
$$;

create or replace function public.mora_finalize_ai_analysis_v2(
  p_user_id uuid,
  p_request_id uuid,
  p_validated_calls jsonb
)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $$
  select public.mora_finalize_ai_analysis_v2(p_user_id, p_request_id, p_validated_calls, 3);
$$;

notify pgrst, 'reload schema';

commit;
