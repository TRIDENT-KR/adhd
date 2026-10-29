-- Mora StoreKit multi-account claim (2026-10-29). Additive migration.
--
-- Every app install now signs in as a Supabase anonymous user (JWT role
-- `authenticated`, `is_anonymous: true`), so a reinstall or a second device is
-- a different Mora account. Pro follows the Apple subscription instead:
--   * register is unchanged: the signed appAccountToken must be the caller's.
--   * claim lets another account signed in to the same Apple ID share an
--     original transaction that currently grants access. The token is not
--     compared; the Apple-signed transaction for that original transaction is
--     the proof. Rebind markers are neither required nor consumed.
--   * one original transaction serves at most 5 accounts (owner + claims). A
--     claim over the cap evicts the least recently claimed accounts.
--   * an entitlement counts owned OR claimed transactions, and every Apple
--     event recomputes the owner and every claimer.
-- Deploy after 202609300001 and before storekit-sync starts sending `claim`.

do $schema$
declare s text;
begin
  foreach s in array array['mora_prod_private', 'mora_stage_private'] loop
    -- user_id references the environment binding rather than auth.users so the
    -- data-purge phase of account deletion (which deletes that row) also erases
    -- the claims. Auth deletion cascades through account_environment as well.
    -- Deleting the binding (retention cleanup) removes its claims.
    execute format($ddl$
      create table if not exists %I.storekit_transaction_claims (
        apple_environment text not null check (apple_environment in ('Sandbox', 'Production')),
        original_transaction_id text not null,
        user_id uuid not null references mora_internal.account_environment(user_id) on delete cascade,
        first_claimed_at timestamptz not null default clock_timestamp(),
        last_claimed_at timestamptz not null default clock_timestamp(),
        primary key (apple_environment, original_transaction_id, user_id),
        foreign key (apple_environment, original_transaction_id)
          references %I.storekit_transaction_bindings (apple_environment, original_transaction_id)
          on delete cascade
      )
    $ddl$, s, s);
    execute format(
      'create index if not exists %I on %I.storekit_transaction_claims (user_id)',
      s || '_storekit_claim_user_idx',
      s
    );
    execute format('alter table %I.storekit_transaction_claims enable row level security', s);
    execute format('revoke all on %I.storekit_transaction_claims from public, anon, authenticated', s);
  end loop;
end;
$schema$;

-- Recomputes one account's entitlement from the bindings it owns OR has
-- claimed. The best binding is one that currently grants access; otherwise
-- the latest one. is_pro and mora_get_entitlement read this row.
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
      from (
        select b.* from %I.storekit_transaction_bindings b
         where b.user_id = $1
        union all
        select b.* from %I.storekit_transaction_bindings b
          join %I.storekit_transaction_claims c
            on c.apple_environment = b.apple_environment
           and c.original_transaction_id = b.original_transaction_id
         where c.user_id = $1
      ) held
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
  $sql$, p_schema, p_schema, p_schema)
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

-- Recomputes the owner (if any) and every claimer of one original transaction.
create or replace function mora_internal.storekit_recompute_transaction_holders(
  p_schema text,
  p_apple_environment text,
  p_original_transaction_id text
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_holder uuid;
begin
  if p_schema not in ('mora_prod_private', 'mora_stage_private') then
    raise exception 'invalid_private_schema' using errcode = '22023';
  end if;
  for v_holder in execute format($sql$
    select user_id from %I.storekit_transaction_bindings
     where apple_environment = $1 and original_transaction_id = $2 and user_id is not null
    union
    select user_id from %I.storekit_transaction_claims
     where apple_environment = $1 and original_transaction_id = $2
  $sql$, p_schema, p_schema)
    using p_apple_environment, p_original_transaction_id
  loop
    perform mora_internal.storekit_recompute_entitlement(p_schema, v_holder);
  end loop;
end;
$$;

-- At most 5 accounts per original transaction: the owner plus claims. Owners
-- are never evicted; the least recently claimed accounts lose access first.
-- Callers hold the per-transaction advisory lock.
create or replace function mora_internal.storekit_enforce_account_cap(
  p_schema text,
  p_apple_environment text,
  p_original_transaction_id text,
  p_keep_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_max_accounts constant integer := 5;
  v_owner_count integer;
  v_claim_count integer;
  v_evicted uuid;
begin
  if p_schema not in ('mora_prod_private', 'mora_stage_private') then
    raise exception 'invalid_private_schema' using errcode = '22023';
  end if;
  execute format($sql$
    select (select count(*) from %I.storekit_transaction_bindings
             where apple_environment = $1 and original_transaction_id = $2
               and user_id is not null),
           (select count(*) from %I.storekit_transaction_claims
             where apple_environment = $1 and original_transaction_id = $2)
  $sql$, p_schema, p_schema)
    into v_owner_count, v_claim_count
    using p_apple_environment, p_original_transaction_id;
  if v_owner_count + v_claim_count <= v_max_accounts then
    return;
  end if;

  for v_evicted in execute format($sql$
    delete from %I.storekit_transaction_claims
     where apple_environment = $1 and original_transaction_id = $2
       and user_id in (
         select user_id from %I.storekit_transaction_claims
          where apple_environment = $1 and original_transaction_id = $2
            and user_id is distinct from $3
          order by last_claimed_at, first_claimed_at, user_id
          limit $4
       )
    returning user_id
  $sql$, p_schema, p_schema)
    using p_apple_environment, p_original_transaction_id, p_keep_user_id,
          v_owner_count + v_claim_count - v_max_accounts
  loop
    perform mora_internal.storekit_recompute_entitlement(p_schema, v_evicted);
  end loop;
end;
$$;

revoke all on function mora_internal.storekit_recompute_entitlement(text, uuid) from public, anon, authenticated;
revoke all on function mora_internal.storekit_recompute_transaction_holders(text, text, text) from public, anon, authenticated;
revoke all on function mora_internal.storekit_enforce_account_cap(text, text, text, uuid) from public, anon, authenticated;

-- Called by storekit-sync after verifying the app-supplied transaction JWS.
--   register: the JWS appAccountToken must be this account's token (unchanged).
--   rebind:   explicit Restore after the previous owner was deleted (unchanged).
--   claim:    the subscription was found in Transaction.currentEntitlements,
--             but its token names an older account (reinstall, other device).
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
  v_grants_access boolean;
begin
  perform mora_internal.require_service_role();
  perform mora_internal.storekit_validate_evidence(p_signed_at, p_purchased_at);
  if p_mode is null or p_mode not in ('register', 'rebind', 'claim') then
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

  -- Serialize every writer (app, restore, claim, notifications) on this transaction.
  perform pg_advisory_xact_lock(
    hashtextextended('mora_storekit:' || p_apple_environment || ':' || p_original_transaction_id, 0)
  );

  execute format('select app_account_token from %I.storekit_accounts where user_id = $1', v_schema)
    into v_account_token using p_user_id;
  -- claim never compares the token, so it does not need one of its own.
  if v_account_token is null and p_mode <> 'claim' then
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
  elsif p_mode = 'rebind' then
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
  else
    -- claim: the token names another Mora account, so it is neither compared
    -- nor stored for this one.
    if v_rows = 0 then
      execute format($sql$
        insert into %I.storekit_transaction_bindings (
          apple_environment, original_transaction_id, latest_transaction_id,
          user_id, app_account_token, product_id, state, purchased_at,
          expires_at, grace_expires_at, revoked_at, verified_at, evidence_signed_at, evidence_source
        )
        values ($1, $2, $3, $4, null, $5, $6, $7, $8, $9, $10, clock_timestamp(), $11, 'transaction')
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_transaction_id,
              p_user_id, p_product_id, p_state, p_purchased_at, p_expires_at,
              case when p_state = 'grace' then p_grace_expires_at end,
              p_revoked_at, p_signed_at;
      v_result := 'bound';
    elsif v_owner = p_user_id then
      v_result := 'updated';
    else
      -- Owned by another account, or by nobody after that account was deleted.
      execute format($sql$
        insert into %I.storekit_transaction_claims (
          apple_environment, original_transaction_id, user_id
        )
        values ($1, $2, $3)
        on conflict (apple_environment, original_transaction_id, user_id)
        do update set last_claimed_at = clock_timestamp()
      $sql$, v_schema)
        using p_apple_environment, p_original_transaction_id, p_user_id;
      v_result := 'claimed';
    end if;
  end if;

  if v_result <> 'bound' or v_rows > 0 then
    perform mora_internal.storekit_update_binding_facts_v2(
      v_schema, p_apple_environment, p_original_transaction_id, p_transaction_id,
      p_product_id, p_state, p_purchased_at, p_expires_at, p_grace_expires_at,
      p_revoked_at, p_signed_at, 'transaction', null
    );
  end if;

  if p_mode = 'claim' then
    -- Judge the ledger after this evidence, not the JWS alone: a transaction
    -- JWS never proves billing grace, and an older or reordered JWS must not
    -- revive a refunded/expired subscription. Only the latest transaction of a
    -- currently entitling subscription can be claimed. Raising rolls back the
    -- binding/claim written above.
    execute format($sql$
      select latest_transaction_id = $3
             and ((state = 'active' and expires_at > clock_timestamp())
                  or (state = 'grace' and grace_expires_at > clock_timestamp()))
        from %I.storekit_transaction_bindings
       where apple_environment = $1 and original_transaction_id = $2
    $sql$, v_schema)
      into v_grants_access
      using p_apple_environment, p_original_transaction_id, p_transaction_id;
    if not coalesce(v_grants_access, false) then
      raise exception 'claim_not_active' using errcode = '55000';
    end if;
  end if;

  if v_result in ('bound', 'transferred', 'rebound') then
    -- The caller now owns the binding; an earlier claim would count twice.
    execute format($sql$
      delete from %I.storekit_transaction_claims
       where apple_environment = $1 and original_transaction_id = $2 and user_id = $3
    $sql$, v_schema)
      using p_apple_environment, p_original_transaction_id, p_user_id;
  end if;
  perform mora_internal.storekit_enforce_account_cap(
    v_schema, p_apple_environment, p_original_transaction_id, p_user_id
  );

  perform mora_internal.storekit_recompute_transaction_holders(
    v_schema, p_apple_environment, p_original_transaction_id
  );
  if v_previous_owner is not null then
    perform mora_internal.storekit_recompute_entitlement(v_schema, v_previous_owner);
  end if;

  return jsonb_build_object('result', v_result);
end;
$$;

-- Called by app-store-notifications after verifying signedPayload and its
-- nested JWS. Notifications update state but never move ownership, except to
-- bind a not-yet-registered transaction to the account its token names.
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
  v_owner_state text;
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
        select user_id, state from %I.storekit_transaction_bindings
         where apple_environment = $1 and original_transaction_id = $2
         for update
      $sql$, v_candidate)
        into v_owner, v_owner_state using p_apple_environment, p_original_transaction_id;
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
      -- The owner was deleted; claimers of this subscription still follow it.
      v_result := 'updated';
      perform mora_internal.storekit_update_binding_facts_v2(
        v_schema, p_apple_environment, p_original_transaction_id, p_transaction_id,
        p_product_id, p_state, p_purchased_at, p_expires_at, p_grace_expires_at,
        p_revoked_at, p_signed_at, 'notification', p_notification_type
      );
      perform mora_internal.storekit_recompute_transaction_holders(
        v_schema, p_apple_environment, p_original_transaction_id
      );
    elsif v_owner is not null then
      -- A re-purchase may carry another live account's token. Its notification
      -- can arrive before that account's authenticated register request. Do not
      -- grant the new purchase to the previous owner (or change their expired
      -- state to active and thereby prevent the legitimate transfer).
      -- Hold only while such a transfer is possible (owner's access ended). An
      -- entitling subscription cannot transfer; its events (renewal, upgrade
      -- from a claimer's install, a claim-created binding whose token names an
      -- older account) describe the same Apple subscription and must apply.
      if p_app_account_token is not null then
        execute format('select user_id from %I.storekit_accounts where app_account_token = $1', v_schema)
          into v_token_owner using p_app_account_token;
      end if;
      if v_token_owner is not null and v_token_owner <> v_owner
         and v_owner_state in ('expired', 'revoked', 'refunded') then
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
        perform mora_internal.storekit_recompute_transaction_holders(
          v_schema, p_apple_environment, p_original_transaction_id
        );
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

revoke all on function public.mora_storekit_apply_transaction_v2(uuid, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.mora_storekit_apply_notification_v2(uuid, text, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.mora_storekit_apply_transaction_v2(uuid, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;
grant execute on function public.mora_storekit_apply_notification_v2(uuid, text, text, text, text, text, uuid, text, text, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;

-- Same as 202609300001 except that an orphan binding (owner deleted) is kept
-- while live accounts still claim it. Claims leave with their account (purge
-- or Auth deletion) or by cap eviction; the binding's original deadline then
-- applies again.
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

  -- Lock the selected rows so explicit Restore or a claim cannot race with
  -- their deletion. A claimed orphan still serves live accounts.
  execute format(
    'delete from %I.storekit_transaction_bindings where (apple_environment, original_transaction_id) in (select b.apple_environment, b.original_transaction_id from %I.storekit_transaction_bindings b where b.user_id is null and b.retain_until <= clock_timestamp() and not exists (select 1 from %I.storekit_transaction_claims c where c.apple_environment = b.apple_environment and c.original_transaction_id = b.original_transaction_id) order by b.retain_until limit $1 for update of b skip locked)',
    p_schema, p_schema, p_schema
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
