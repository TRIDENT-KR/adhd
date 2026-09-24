-- Mora StoreKit server write path (release QA-003).
--
-- Edge Functions verify Apple-signed JWS (transaction, renewal info, App Store
-- Server Notification V2) before calling anything here. These RPCs accept only
-- already-verified facts, run as service_role, and enforce:
--   * one Mora account per original transaction (single ownership)
--   * binding only when the Apple-signed appAccountToken proves the purchase
--     was made under that account, or through an explicit Restore that
--     consumes a rebind marker left by account deletion (never automatically)
--   * staging accounts accept only Sandbox transactions; production accounts
--     accept Production and Sandbox (App Review purchases in Sandbox)

create or replace function mora_internal.storekit_account_schema(p_user_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, mora_internal
as $$
declare
  v_environment text;
begin
  if p_user_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if exists (
    select 1 from mora_internal.account_deletion_locks where user_id = p_user_id
  ) then
    raise exception 'account_deletion_pending' using errcode = '42501';
  end if;
  select environment
    into v_environment
    from mora_internal.account_environment
   where user_id = p_user_id;
  if v_environment is null then
    -- The app always calls mora_get_app_account_token (which binds the
    -- environment) before purchasing or restoring.
    raise exception 'environment_unbound' using errcode = '55000';
  end if;
  return mora_internal.schema_for_environment(v_environment);
end;
$$;

revoke all on function mora_internal.storekit_account_schema(uuid) from public, anon, authenticated;

create or replace function mora_internal.storekit_validate_facts(
  p_apple_environment text,
  p_original_transaction_id text,
  p_transaction_id text,
  p_product_id text,
  p_state text,
  p_expires_at timestamptz,
  p_grace_expires_at timestamptz
)
returns void
language plpgsql
immutable
set search_path = pg_catalog
as $$
begin
  if p_apple_environment is null or p_apple_environment not in ('Sandbox', 'Production') then
    raise exception 'invalid_apple_environment' using errcode = '22023';
  end if;
  if p_original_transaction_id is null or p_original_transaction_id !~ '^[0-9]{1,40}$'
     or p_transaction_id is null or p_transaction_id !~ '^[0-9]{1,40}$' then
    raise exception 'invalid_transaction_id' using errcode = '22023';
  end if;
  if p_product_id is null
     or p_product_id not in ('com.TRIDENT.ADHD.monthly', 'com.TRIDENT.ADHD.yearly') then
    raise exception 'unknown_product' using errcode = '22023';
  end if;
  if p_state is null
     or p_state not in ('active', 'grace', 'billing_retry', 'expired', 'revoked', 'refunded')
     or (p_state = 'active' and p_expires_at is null)
     or (p_state = 'grace' and p_grace_expires_at is null) then
    raise exception 'invalid_subscription_state' using errcode = '22023';
  end if;
end;
$$;

revoke all on function mora_internal.storekit_validate_facts(text, text, text, text, text, timestamptz, timestamptz) from public, anon, authenticated;

-- Recomputes one account's entitlement from the bindings it owns. The best
-- binding is one that currently grants access; otherwise the latest one.
create or replace function mora_internal.storekit_recompute_entitlement(
  p_schema text,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_original_transaction_id text;
  v_product_id text;
  v_state text;
  v_verified_at timestamptz;
  v_expires_at timestamptz;
  v_grace_expires_at timestamptz;
  v_access_until timestamptz;
begin
  if p_schema not in ('mora_prod_private', 'mora_stage_private') then
    raise exception 'invalid_private_schema' using errcode = '22023';
  end if;
  if p_user_id is null then
    return;
  end if;

  execute format($sql$
    select original_transaction_id, product_id, state, verified_at, expires_at,
           grace_expires_at,
           case state
             when 'active' then expires_at
             when 'grace' then grace_expires_at
           end
      from %I.storekit_transaction_bindings
     where user_id = $1
     order by
       case
         when state = 'active' and expires_at > clock_timestamp() then 0
         when state = 'grace' and grace_expires_at > clock_timestamp() then 0
         else 1
       end,
       coalesce(
         case state when 'grace' then grace_expires_at else expires_at end,
         '-infinity'::timestamptz
       ) desc,
       updated_at desc
     limit 1
  $sql$, p_schema)
    into v_original_transaction_id, v_product_id, v_state, v_verified_at,
         v_expires_at, v_grace_expires_at, v_access_until
    using p_user_id;

  if v_original_transaction_id is null then
    execute format('delete from %I.account_entitlements where user_id = $1', p_schema)
      using p_user_id;
    return;
  end if;

  execute format($sql$
    insert into %I.account_entitlements (
      user_id, product_id, status, verified_at, expires_at, grace_expires_at,
      access_until, original_transaction_id, updated_at
    )
    values ($1, $2, $3, $4, $5, $6, $7, $8, clock_timestamp())
    on conflict (user_id) do update set
      product_id = excluded.product_id,
      status = excluded.status,
      verified_at = excluded.verified_at,
      expires_at = excluded.expires_at,
      grace_expires_at = excluded.grace_expires_at,
      access_until = excluded.access_until,
      original_transaction_id = excluded.original_transaction_id,
      updated_at = excluded.updated_at
  $sql$, p_schema)
    using p_user_id, v_product_id, v_state, v_verified_at, v_expires_at,
          case when v_state = 'grace' then v_grace_expires_at end,
          v_access_until, v_original_transaction_id;
end;
$$;

revoke all on function mora_internal.storekit_recompute_entitlement(text, uuid) from public, anon, authenticated;

-- Writes verified facts onto an existing binding when they are not older than
-- what is stored. A late-arriving older transaction never rolls state back.
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
declare
  v_rows integer;
begin
  execute format($sql$
    update %I.storekit_transaction_bindings
       set latest_transaction_id = $3,
           product_id = $4,
           state = $5,
           purchased_at = $6,
           expires_at = $7,
           grace_expires_at = $8,
           revoked_at = $9,
           verified_at = clock_timestamp(),
           updated_at = clock_timestamp()
     where apple_environment = $1
       and original_transaction_id = $2
       and (
         latest_transaction_id is null
         or latest_transaction_id = $3
         or coalesce($7, '-infinity'::timestamptz)
            >= coalesce(expires_at, '-infinity'::timestamptz)
       )
  $sql$, p_schema)
    using p_apple_environment, p_original_transaction_id, p_transaction_id,
          p_product_id, p_state, p_purchased_at, p_expires_at,
          case when p_state = 'grace' then p_grace_expires_at end,
          p_revoked_at;
  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;

revoke all on function mora_internal.storekit_update_binding_facts(text, text, text, text, text, text, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;

-- Called by storekit-sync after verifying the app-supplied transaction JWS.
--   register: the JWS appAccountToken must be this account's token.
--   rebind:   explicit Restore of a subscription whose previous Mora account
--             was deleted; consumes that deletion's rebind marker once.
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

  if p_mode = 'register' then
    if p_app_account_token is distinct from v_account_token then
      raise exception 'app_account_token_mismatch' using errcode = '42501';
    end if;

    if v_rows = 0 then
      execute format($sql$
        insert into %I.storekit_transaction_bindings (
          apple_environment, original_transaction_id, latest_transaction_id,
          user_id, app_account_token, product_id, state, purchased_at,
          expires_at, grace_expires_at, revoked_at, verified_at
        )
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, clock_timestamp())
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_transaction_id,
              p_user_id, p_app_account_token, p_product_id, p_state,
              p_purchased_at, p_expires_at,
              case when p_state = 'grace' then p_grace_expires_at end,
              p_revoked_at;
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
    perform mora_internal.storekit_update_binding_facts(
      v_schema, p_apple_environment, p_original_transaction_id, p_transaction_id,
      p_product_id, p_state, p_purchased_at, p_expires_at, p_grace_expires_at,
      p_revoked_at
    );
  end if;

  perform mora_internal.storekit_recompute_entitlement(v_schema, p_user_id);
  if v_previous_owner is not null then
    perform mora_internal.storekit_recompute_entitlement(v_schema, v_previous_owner);
  end if;

  return jsonb_build_object('result', v_result);
end;
$$;

-- Called by app-store-notifications after verifying signedPayload and its
-- nested JWS. Notifications update state but never move ownership, except to
-- bind a not-yet-registered transaction to the account its token names.
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
      perform mora_internal.storekit_update_binding_facts(
        v_schema, p_apple_environment, p_original_transaction_id, p_transaction_id,
        p_product_id, p_state, p_purchased_at, p_expires_at, p_grace_expires_at,
        p_revoked_at
      );
    elsif v_owner is not null then
      v_result := 'updated';
      perform mora_internal.storekit_update_binding_facts(
        v_schema, p_apple_environment, p_original_transaction_id, p_transaction_id,
        p_product_id, p_state, p_purchased_at, p_expires_at, p_grace_expires_at,
        p_revoked_at
      );
      perform mora_internal.storekit_recompute_entitlement(v_schema, v_owner);
    elsif v_token_owner is not null
          and not exists (
            select 1 from mora_internal.account_deletion_locks where user_id = v_token_owner
          ) then
      execute format($sql$
        insert into %I.storekit_transaction_bindings (
          apple_environment, original_transaction_id, latest_transaction_id,
          user_id, app_account_token, product_id, state, purchased_at,
          expires_at, grace_expires_at, revoked_at, verified_at
        )
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, clock_timestamp())
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_transaction_id,
              v_token_owner, p_app_account_token, p_product_id, p_state,
              p_purchased_at, p_expires_at,
              case when p_state = 'grace' then p_grace_expires_at end,
              p_revoked_at;
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

revoke all on function public.mora_storekit_apply_transaction(uuid, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.mora_storekit_apply_notification(uuid, text, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.mora_storekit_apply_transaction(uuid, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;
grant execute on function public.mora_storekit_apply_notification(uuid, text, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;
