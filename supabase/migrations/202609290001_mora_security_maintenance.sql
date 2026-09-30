-- Keep full daily totals when bounded retention deletes raw events in batches.
-- Operational durations/counts are non-negative; subsequent partial groups must
-- never replace the previously observed full totals during the 90-day window.
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
      event_count = greatest(daily_operational_aggregates.event_count, excluded.event_count),
      total_duration_ms = greatest(daily_operational_aggregates.total_duration_ms, excluded.total_duration_ms),
      max_duration_ms = greatest(daily_operational_aggregates.max_duration_ms, excluded.max_duration_ms),
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

-- Expired AI content and security records must be physically removed, not only
-- hidden by read-time expiry checks. Supabase includes pg_cron; standalone local
-- PostgreSQL used by the offline tests may not include this optional extension.
do $maintenance$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron unavailable: retention scheduling requires a supported deployment database';
    return;
  end if;

  -- CLI may connect using a temporary login that can assume postgres.
  -- pg_cron must connect as postgres because cleanup checks session_user.
  execute 'set local role postgres';
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.schedule(
    'mora-security-retention',
    '*/5 * * * *',
    'select public.mora_cleanup_security_data(5000);'
  );

  if not exists (
    select 1 from cron.job
     where jobname = 'mora-security-retention' and active
       and username = 'postgres' and database = current_database()
       and schedule = '*/5 * * * *'
       and command = 'select public.mora_cleanup_security_data(5000);'
  ) then
    raise exception 'Mora retention schedule was not installed';
  end if;
end;
$maintenance$;
