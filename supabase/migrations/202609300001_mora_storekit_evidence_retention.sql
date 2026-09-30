-- Release audit AR-03/04/11. Additive migration: preserve old migration history.
-- Deploy this migration before the v2 StoreKit Edge Functions. Legacy RPCs fail
-- closed during the brief rollout window rather than accepting unordered facts.

-- Apple evidence is ordered by signed time within a transaction and by purchase
-- time across distinct transactions. Never order Apple IDs lexicographically.
do $schema$
declare s text;
begin
  foreach s in array array['mora_prod_private', 'mora_stage_private'] loop
    execute format('alter table %I.storekit_transaction_bindings add column if not exists evidence_signed_at timestamptz', s);
    execute format('alter table %I.storekit_transaction_bindings add column if not exists evidence_source text not null default ''legacy'' check (evidence_source in (''legacy'', ''transaction'', ''notification''))', s);
    execute format('alter table %I.storekit_transaction_bindings add column if not exists evidence_notification_type text', s);
    execute format('alter table %I.storekit_transaction_bindings add column if not exists deleted_at timestamptz', s);
    execute format('alter table %I.storekit_transaction_bindings add column if not exists retain_until timestamptz', s);
    -- Existing orphan rows get a fixed deadline. Prefer the deletion marker's
    -- actual deletion time; updated_at alone could reflect a later Apple event.
    execute format($backfill$
      update %I.storekit_transaction_bindings b
         set deleted_at = coalesce(
               (select m.eligible_at from %I.storekit_rebind_markers m
                 where m.apple_environment = b.apple_environment and m.original_transaction_id = b.original_transaction_id),
               b.updated_at),
             retain_until = coalesce(
               (select least(m.retain_until, m.eligible_at + interval '400 days') from %I.storekit_rebind_markers m
                 where m.apple_environment = b.apple_environment and m.original_transaction_id = b.original_transaction_id),
               b.updated_at + interval '30 days'),
             app_account_token = null
       where b.user_id is null and b.retain_until is null
    $backfill$, s, s, s);
    execute format('create index if not exists %I on %I.storekit_transaction_bindings (retain_until) where user_id is null', s || '_orphan_binding_retention_idx', s);
  end loop;
end;
$schema$;

create or replace function mora_internal.storekit_validate_evidence(
  p_signed_at timestamptz, p_purchased_at timestamptz
)
returns void
language plpgsql
set search_path = pg_catalog
as $$
begin
  if p_signed_at is null or not isfinite(p_signed_at)
     or p_signed_at <= '1970-01-01 UTC'::timestamptz
     or p_signed_at > clock_timestamp() + interval '60 seconds' then
    raise exception 'invalid_signed_date' using errcode = '22023';
  end if;
  if p_purchased_at is null or not isfinite(p_purchased_at)
     or p_purchased_at <= '1970-01-01 UTC'::timestamptz
     or p_purchased_at > p_signed_at + interval '60 seconds' then
    raise exception 'invalid_purchase_date' using errcode = '22023';
  end if;
end;
$$;
revoke all on function mora_internal.storekit_validate_evidence(timestamptz, timestamptz) from public, anon, authenticated;

create or replace function mora_internal.storekit_accept_evidence(
  p_current jsonb, p_transaction_id text, p_purchased_at timestamptz,
  p_state text, p_signed_at timestamptz, p_source text, p_notification_type text
)
returns boolean
language plpgsql
immutable
set search_path = pg_catalog
as $$
declare
  old_state text := p_current->>'state';
  old_source text := p_current->>'evidence_source';
  old_signed_at timestamptz := (p_current->>'evidence_signed_at')::timestamptz;
  old_purchased_at timestamptz := (p_current->>'purchased_at')::timestamptz;
  old_rank integer;
  new_rank integer;
begin
  if p_signed_at is null or p_purchased_at is null
     or p_source not in ('transaction', 'notification') then return false; end if;
  if p_current is null or p_current->>'latest_transaction_id' is null then return true; end if;

  if p_current->>'latest_transaction_id' <> p_transaction_id then
    -- A delayed refund of an old renewal must not replace a newer purchase.
    -- Conversely, a newer purchase remains valid even when an old refund was
    -- signed later. Equal purchase times with different IDs are ambiguous.
    return p_purchased_at > coalesce(old_purchased_at, '-infinity'::timestamptz);
  end if;

  if old_signed_at is not null and p_signed_at < old_signed_at then return false; end if;
  if old_state in ('refunded', 'revoked') and p_state not in ('refunded', 'revoked') then
    -- A transaction without revocation fields does not prove refund reversal.
    if p_source <> 'notification' or p_notification_type is distinct from 'REFUND_REVERSED'
       or (old_signed_at is not null and p_signed_at <= old_signed_at) then return false; end if;
  end if;

  if p_source = 'transaction' then
    -- Transaction.currentEntitlements includes grace-period subscriptions but
    -- its transaction JWS carries no renewal/grace evidence. Never erase it.
    if old_state = 'grace' and p_state not in ('refunded', 'revoked') then return false; end if;
    if old_source = 'notification' and p_state not in ('refunded', 'revoked') then return false; end if;
  elsif old_state = 'grace' and p_state in ('expired', 'billing_retry')
        and p_notification_type not in ('EXPIRED', 'GRACE_PERIOD_EXPIRED', 'DID_FAIL_TO_RENEW') then
    -- Informational notifications without renewal data do not end grace.
    return false;
  end if;

  if old_signed_at is null or p_signed_at > old_signed_at then return true; end if;
  -- Equal signed times never restore access from a more restrictive state.
  -- A signed notification may upgrade the evidence source for identical state.
  old_rank := case old_state when 'revoked' then 6 when 'refunded' then 5
    when 'expired' then 4 when 'billing_retry' then 3 when 'grace' then 2 else 1 end;
  new_rank := case p_state when 'revoked' then 6 when 'refunded' then 5
    when 'expired' then 4 when 'billing_retry' then 3 when 'grace' then 2 else 1 end;
  return new_rank > old_rank or
    (new_rank = old_rank and p_source = 'notification' and old_source <> 'notification');
end;
$$;
revoke all on function mora_internal.storekit_accept_evidence(jsonb, text, timestamptz, text, timestamptz, text, text) from public, anon, authenticated;

create or replace function mora_internal.storekit_update_binding_facts_v2(
  p_schema text, p_apple_environment text, p_original_transaction_id text,
  p_transaction_id text, p_product_id text, p_state text,
  p_purchased_at timestamptz, p_expires_at timestamptz, p_grace_expires_at timestamptz,
  p_revoked_at timestamptz, p_signed_at timestamptz, p_source text, p_notification_type text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare current_facts jsonb;
begin
  if p_schema not in ('mora_prod_private', 'mora_stage_private') then
    raise exception 'invalid_private_schema' using errcode = '22023';
  end if;
  perform mora_internal.storekit_validate_evidence(p_signed_at, p_purchased_at);
  execute format('select to_jsonb(b) from %I.storekit_transaction_bindings b where apple_environment = $1 and original_transaction_id = $2 for update', p_schema)
    into current_facts using p_apple_environment, p_original_transaction_id;
  if current_facts is null or not mora_internal.storekit_accept_evidence(
    current_facts, p_transaction_id, p_purchased_at, p_state, p_signed_at, p_source, p_notification_type
  ) then return false; end if;
  execute format($write$
    update %I.storekit_transaction_bindings
       set latest_transaction_id = $3, product_id = $4, state = $5,
           purchased_at = $6, expires_at = $7, grace_expires_at = $8,
           revoked_at = $9, evidence_signed_at = $10, evidence_source = $11,
           evidence_notification_type = $12,
           verified_at = clock_timestamp(), updated_at = clock_timestamp()
     where apple_environment = $1 and original_transaction_id = $2
  $write$, p_schema)
    using p_apple_environment, p_original_transaction_id, p_transaction_id,
          p_product_id, p_state, p_purchased_at, p_expires_at,
          case when p_state = 'grace' then p_grace_expires_at end, p_revoked_at,
          p_signed_at, p_source, p_notification_type;
  return true;
end;
$$;
revoke all on function mora_internal.storekit_update_binding_facts_v2(text, text, text, text, text, text, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, text, text) from public, anon, authenticated;

-- The account-deletion RPC already creates a bounded rebind marker before
-- detaching ownership. This trigger covers that path AND auth FK deletion.
-- Subsequent Apple events cannot reset/extend the deadline. A legitimate rebind
-- clears deletion retention because the subscription belongs to a live account.
create or replace function mora_internal.storekit_binding_retention()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare marker_until timestamptz;
begin
  if new.user_id is not null then
    new.deleted_at := null;
    new.retain_until := null;
  elsif tg_op = 'UPDATE' and old.user_id is null and old.retain_until is not null then
    new.deleted_at := old.deleted_at;
    new.retain_until := old.retain_until;
    new.app_account_token := null;
  else
    new.deleted_at := clock_timestamp();
    execute format('select retain_until from %I.storekit_rebind_markers where apple_environment = $1 and original_transaction_id = $2', tg_table_schema)
      into marker_until using new.apple_environment, new.original_transaction_id;
    new.retain_until := least(
      coalesce(marker_until, new.deleted_at + interval '30 days'),
      new.deleted_at + interval '400 days'
    );
    new.app_account_token := null;
  end if;
  return new;
end;
$$;
revoke all on function mora_internal.storekit_binding_retention() from public, anon, authenticated;
do $triggers$
declare s text;
begin
  foreach s in array array['mora_prod_private', 'mora_stage_private'] loop
    execute format('drop trigger if exists storekit_binding_retention on %I.storekit_transaction_bindings', s);
    execute format('create trigger storekit_binding_retention before insert or update on %I.storekit_transaction_bindings for each row execute function mora_internal.storekit_binding_retention()', s);
  end loop;
end;
$triggers$;

create or replace function public.mora_storekit_apply_transaction_v2(
  p_user_id uuid,
  p_mode text,
  p_apple_environment text,
  p_original_transaction_id text,
  p_transaction_id text,
  p_app_account_token uuid,
  p_product_id text,
  p_state text,
  p_purchased_at timestamptz,
  p_expires_at timestamptz,
  p_grace_expires_at timestamptz,
  p_revoked_at timestamptz,
  p_signed_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_schema text;
  v_account_token uuid;
  v_rows integer;
  v_owner uuid;
  v_owner_state text;
  v_owner_purchased_at timestamptz;
  v_previous_owner uuid;
  v_result text;
begin
  perform mora_internal.require_service_role();
  perform mora_internal.storekit_validate_evidence(p_signed_at, p_purchased_at);
  if p_mode is null or p_mode not in ('register', 'rebind') then
    raise exception 'invalid_mode' using errcode = '22023';
  end if;
  perform mora_internal.storekit_validate_facts(
    p_apple_environment, p_original_transaction_id, p_transaction_id,
    p_product_id, p_state, p_expires_at, p_grace_expires_at
  );

  v_schema := mora_internal.storekit_account_schema(p_user_id);
  if v_schema = 'mora_stage_private' and p_apple_environment <> 'Sandbox' then
    raise exception 'apple_environment_not_allowed' using errcode = '42501';
  end if;

  -- Serialize every writer (app, restore, notifications) on this transaction.
  perform pg_advisory_xact_lock(
    hashtextextended('mora_storekit:' || p_apple_environment || ':' || p_original_transaction_id, 0)
  );

  execute format('select app_account_token from %I.storekit_accounts where user_id = $1', v_schema)
    into v_account_token using p_user_id;
  if v_account_token is null then
    raise exception 'app_account_token_missing' using errcode = '55000';
  end if;

  execute format($sql$
    select user_id, state, purchased_at
      from %I.storekit_transaction_bindings
     where apple_environment = $1 and original_transaction_id = $2
     for update
  $sql$, v_schema)
    into v_owner, v_owner_state, v_owner_purchased_at
    using p_apple_environment, p_original_transaction_id;
  get diagnostics v_rows = row_count;

  if p_mode = 'register' and p_app_account_token is distinct from v_account_token then
    raise exception 'app_account_token_mismatch' using errcode = '42501';
  end if;
  if v_rows > 0 and v_owner is distinct from p_user_id and p_mode = 'register' then
    if not (select mora_internal.storekit_accept_evidence(to_jsonb(b), p_transaction_id,
      p_purchased_at, p_state, p_signed_at, 'transaction', null)
      from mora_prod_private.storekit_transaction_bindings b
      where v_schema = 'mora_prod_private' and apple_environment = p_apple_environment and original_transaction_id = p_original_transaction_id
      union all
      select mora_internal.storekit_accept_evidence(to_jsonb(b), p_transaction_id,
      p_purchased_at, p_state, p_signed_at, 'transaction', null)
      from mora_stage_private.storekit_transaction_bindings b
      where v_schema = 'mora_stage_private' and apple_environment = p_apple_environment and original_transaction_id = p_original_transaction_id) then
      raise exception 'stale_transaction_evidence' using errcode = '22023';
    end if;
  end if;

  if p_mode = 'register' then
    if p_app_account_token is distinct from v_account_token then
      raise exception 'app_account_token_mismatch' using errcode = '42501';
    end if;

    if v_rows = 0 then
      execute format($sql$
        insert into %I.storekit_transaction_bindings (
          apple_environment, original_transaction_id, latest_transaction_id,
          user_id, app_account_token, product_id, state, purchased_at,
          expires_at, grace_expires_at, revoked_at, verified_at, evidence_signed_at, evidence_source
        )
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, clock_timestamp(), $12, 'transaction')
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_transaction_id,
              p_user_id, p_app_account_token, p_product_id, p_state,
              p_purchased_at, p_expires_at,
              case when p_state = 'grace' then p_grace_expires_at end,
              p_revoked_at, p_signed_at;
      v_result := 'bound';
    elsif v_owner = p_user_id then
      v_result := 'updated';
    elsif v_owner is null then
      -- Previous owner was deleted. A transaction carrying this account's
      -- token is a new purchase made here, so it may take the binding.
      v_result := 'bound';
    elsif v_owner_state in ('expired', 'revoked', 'refunded')
          and p_purchased_at is not null
          and p_purchased_at > coalesce(v_owner_purchased_at, '-infinity'::timestamptz) then
      -- The same Apple ID resubscribed while signed in to this account after
      -- the other account's access ended; the signed token proves it.
      v_previous_owner := v_owner;
      v_result := 'transferred';
    else
      raise exception 'subscription_owned_by_another_account' using errcode = '42501';
    end if;

    if v_result in ('bound', 'transferred') and v_rows > 0 then
      execute format($sql$
        update %I.storekit_transaction_bindings
           set user_id = $3, app_account_token = $4,
               bound_at = clock_timestamp(), updated_at = clock_timestamp()
         where apple_environment = $1 and original_transaction_id = $2
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_user_id, p_app_account_token;
      -- An open rebind marker for this transaction is settled by the new owner.
      execute format($sql$
        update %I.storekit_rebind_markers
           set consumed_by_user_id = $3, consumed_at = clock_timestamp()
         where apple_environment = $1 and original_transaction_id = $2
           and consumed_at is null
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_user_id;
    end if;
  else
    if v_rows = 0 then
      raise exception 'rebind_not_eligible' using errcode = '42501';
    elsif v_owner = p_user_id then
      v_result := 'updated';
    elsif v_owner is not null then
      raise exception 'subscription_owned_by_another_account' using errcode = '42501';
    else
      execute format($sql$
        update %I.storekit_rebind_markers
           set consumed_by_user_id = $3, consumed_at = clock_timestamp()
         where apple_environment = $1 and original_transaction_id = $2
           and consumed_at is null
           and retain_until > clock_timestamp()
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_user_id;
      get diagnostics v_rows = row_count;
      if v_rows = 0 then
        raise exception 'rebind_not_eligible' using errcode = '42501';
      end if;
      -- The JWS token belongs to the deleted account; do not store it again.
      execute format($sql$
        update %I.storekit_transaction_bindings
           set user_id = $3, app_account_token = null,
               bound_at = clock_timestamp(), updated_at = clock_timestamp()
         where apple_environment = $1 and original_transaction_id = $2
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_user_id;
      v_result := 'rebound';
    end if;
  end if;

  if v_result <> 'bound' or v_rows > 0 then
    perform mora_internal.storekit_update_binding_facts_v2(
      v_schema, p_apple_environment, p_original_transaction_id, p_transaction_id,
      p_product_id, p_state, p_purchased_at, p_expires_at, p_grace_expires_at,
      p_revoked_at, p_signed_at, 'transaction', null
    );
  end if;

  perform mora_internal.storekit_recompute_entitlement(v_schema, p_user_id);
  if v_previous_owner is not null then
    perform mora_internal.storekit_recompute_entitlement(v_schema, v_previous_owner);
  end if;

  return jsonb_build_object('result', v_result);
end;
$$;

create or replace function public.mora_storekit_apply_notification_v2(
  p_notification_uuid uuid,
  p_notification_type text,
  p_subtype text,
  p_apple_environment text,
  p_original_transaction_id text,
  p_transaction_id text,
  p_app_account_token uuid,
  p_product_id text,
  p_state text,
  p_purchased_at timestamptz,
  p_expires_at timestamptz,
  p_grace_expires_at timestamptz,
  p_revoked_at timestamptz,
  p_signed_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, auth, mora_internal, mora_prod_private, mora_stage_private
as $$
declare
  v_schema text;
  v_candidate text;
  v_rows integer;
  v_owner uuid;
  v_token_owner uuid;
  v_result text;
begin
  perform mora_internal.require_service_role();
  if p_signed_at is null or not isfinite(p_signed_at)
     or p_signed_at <= '1970-01-01 UTC'::timestamptz
     or p_signed_at > clock_timestamp() + interval '60 seconds' then
    raise exception 'invalid_signed_date' using errcode = '22023';
  end if;
  if p_notification_uuid is null
     or p_notification_type is null or p_notification_type !~ '^[A-Z_]{1,64}$'
     or (p_subtype is not null and p_subtype !~ '^[A-Z_]{1,64}$') then
    raise exception 'invalid_notification' using errcode = '22023';
  end if;
  if p_apple_environment is null or p_apple_environment not in ('Sandbox', 'Production') then
    raise exception 'invalid_apple_environment' using errcode = '22023';
  end if;

  -- Apple retries until it gets 200; a notification is applied at most once.
  foreach v_candidate in array array['mora_prod_private', 'mora_stage_private'] loop
    execute format(
      'select 1 from %I.app_store_notification_events where notification_uuid = $1',
      v_candidate
    ) using p_notification_uuid;
    get diagnostics v_rows = row_count;
    if v_rows > 0 then
      return jsonb_build_object('result', 'duplicate');
    end if;
  end loop;

  if p_original_transaction_id is not null then
    perform mora_internal.storekit_validate_evidence(p_signed_at, p_purchased_at);
    perform mora_internal.storekit_validate_facts(
      p_apple_environment, p_original_transaction_id, p_transaction_id,
      p_product_id, p_state, p_expires_at, p_grace_expires_at
    );
    perform pg_advisory_xact_lock(
      hashtextextended('mora_storekit:' || p_apple_environment || ':' || p_original_transaction_id, 0)
    );

    foreach v_candidate in array array['mora_prod_private', 'mora_stage_private'] loop
      continue when v_candidate = 'mora_stage_private' and p_apple_environment <> 'Sandbox';
      execute format($sql$
        select user_id from %I.storekit_transaction_bindings
         where apple_environment = $1 and original_transaction_id = $2
         for update
      $sql$, v_candidate)
        into v_owner using p_apple_environment, p_original_transaction_id;
      get diagnostics v_rows = row_count;
      if v_rows > 0 then
        v_schema := v_candidate;
        exit;
      end if;
    end loop;

    if v_schema is null and p_app_account_token is not null then
      foreach v_candidate in array array['mora_prod_private', 'mora_stage_private'] loop
        continue when v_candidate = 'mora_stage_private' and p_apple_environment <> 'Sandbox';
        execute format(
          'select user_id from %I.storekit_accounts where app_account_token = $1',
          v_candidate
        ) into v_token_owner using p_app_account_token;
        if v_token_owner is not null then
          v_schema := v_candidate;
          exit;
        end if;
      end loop;
    end if;

    if v_schema is not null and v_owner is null and v_token_owner is null then
      v_result := 'updated';
      perform mora_internal.storekit_update_binding_facts_v2(
        v_schema, p_apple_environment, p_original_transaction_id, p_transaction_id,
        p_product_id, p_state, p_purchased_at, p_expires_at, p_grace_expires_at,
        p_revoked_at, p_signed_at, 'notification', p_notification_type
      );
    elsif v_owner is not null then
      -- A re-purchase may carry another live account's token. Its notification
      -- can arrive before that account's authenticated register request. Do not
      -- grant the new purchase to the previous owner (or change their expired
      -- state to active and thereby prevent the legitimate transfer).
      if p_app_account_token is not null then
        execute format('select user_id from %I.storekit_accounts where app_account_token = $1', v_schema)
          into v_token_owner using p_app_account_token;
      end if;
      if v_token_owner is not null and v_token_owner <> v_owner then
        v_result := 'awaiting_account_registration';
      else
        -- A deleted account's old token no longer resolves. Keep supporting
        -- notifications after an explicit Restore rebound that subscription.
        v_result := 'updated';
        perform mora_internal.storekit_update_binding_facts_v2(
          v_schema, p_apple_environment, p_original_transaction_id, p_transaction_id,
          p_product_id, p_state, p_purchased_at, p_expires_at, p_grace_expires_at,
          p_revoked_at, p_signed_at, 'notification', p_notification_type
        );
        perform mora_internal.storekit_recompute_entitlement(v_schema, v_owner);
      end if;
    elsif v_token_owner is not null
          and not exists (
            select 1 from mora_internal.account_deletion_locks where user_id = v_token_owner
          ) then
      execute format($sql$
        insert into %I.storekit_transaction_bindings (
          apple_environment, original_transaction_id, latest_transaction_id,
          user_id, app_account_token, product_id, state, purchased_at,
          expires_at, grace_expires_at, revoked_at, verified_at, evidence_signed_at, evidence_source, evidence_notification_type
        )
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, clock_timestamp(), $12, 'notification', $13)
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_transaction_id,
              v_token_owner, p_app_account_token, p_product_id, p_state,
              p_purchased_at, p_expires_at,
              case when p_state = 'grace' then p_grace_expires_at end,
              p_revoked_at, p_signed_at, p_notification_type;
      perform mora_internal.storekit_recompute_entitlement(v_schema, v_token_owner);
      v_result := 'bound';
    else
      v_result := 'ignored_unknown_transaction';
    end if;
  else
    v_result := 'recorded';
  end if;

  v_schema := coalesce(
    v_schema,
    case p_apple_environment when 'Production' then 'mora_prod_private' else 'mora_stage_private' end
  );
  execute format($sql$
    insert into %I.app_store_notification_events (
      notification_uuid, notification_type, subtype, apple_environment, processed_at
    )
    values ($1, $2, $3, $4, clock_timestamp())
    on conflict (notification_uuid) do nothing
  $sql$, v_schema)
    using p_notification_uuid, p_notification_type, p_subtype, p_apple_environment;

  return jsonb_build_object('result', v_result);
end;
$$;

create or replace function public.mora_storekit_apply_transaction(
  p_user_id uuid,
  p_mode text,
  p_apple_environment text,
  p_original_transaction_id text,
  p_transaction_id text,
  p_app_account_token uuid,
  p_product_id text,
  p_state text,
  p_purchased_at timestamptz,
  p_expires_at timestamptz,
  p_grace_expires_at timestamptz,
  p_revoked_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform mora_internal.require_service_role();
  raise exception 'storekit_evidence_required' using errcode = '55000';
end;
$$;

create or replace function public.mora_storekit_apply_notification(
  p_notification_uuid uuid,
  p_notification_type text,
  p_subtype text,
  p_apple_environment text,
  p_original_transaction_id text,
  p_transaction_id text,
  p_app_account_token uuid,
  p_product_id text,
  p_state text,
  p_purchased_at timestamptz,
  p_expires_at timestamptz,
  p_grace_expires_at timestamptz,
  p_revoked_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  perform mora_internal.require_service_role();
  raise exception 'storekit_evidence_required' using errcode = '55000';
end;
$$;

create or replace function mora_internal.storekit_update_binding_facts(
  p_schema text,
  p_apple_environment text,
  p_original_transaction_id text,
  p_transaction_id text,
  p_product_id text,
  p_state text,
  p_purchased_at timestamptz,
  p_expires_at timestamptz,
  p_grace_expires_at timestamptz,
  p_revoked_at timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  raise exception 'storekit_evidence_required' using errcode = '55000';
end;
$$;

revoke all on function public.mora_storekit_apply_transaction_v2(uuid, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.mora_storekit_apply_notification_v2(uuid, text, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.mora_storekit_apply_transaction_v2(uuid, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;
grant execute on function public.mora_storekit_apply_notification_v2(uuid, text, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;

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
  v_bindings_deleted integer := 0;
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

  -- Lock the selected rows so explicit Restore cannot race with their deletion.
  execute format(
    'delete from %I.storekit_transaction_bindings where (apple_environment, original_transaction_id) in (select apple_environment, original_transaction_id from %I.storekit_transaction_bindings where user_id is null and retain_until <= clock_timestamp() order by retain_until limit $1 for update skip locked)',
    p_schema, p_schema
  ) using p_batch_size;
  get diagnostics v_bindings_deleted = row_count;

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
    'orphanBindingsDeleted', v_bindings_deleted,
    'aiRequestsDeleted', v_ai_requests_deleted,
    'aiDaysDeleted', v_ai_days_deleted,
    'storeEventsDeleted', v_store_events_deleted,
    'cachedResponsesCleared', v_cached_responses_cleared
  );
end;
$$;

revoke all on function mora_internal.cleanup_schema(text, integer) from public, anon, authenticated;
