-- Internal Pro grants: lets the team use Pro without a StoreKit purchase.
--
-- Why a separate table: account_entitlements is derived from StoreKit bindings.
-- storekit_recompute_entitlement deletes the row of any account that owns no binding,
-- so a hand-written row there disappears on the next purchase / restore sync.
-- A grant lives in its own table that StoreKit code never touches.
--
--   * is_pro (used by the AI quota functions) also returns true for an unexpired grant.
--   * mora_get_entitlement returns the real StoreKit entitlement when that is Pro,
--     otherwise a grant is reported in the exact shape the app validates
--     (status active, a known productId, verifiedAt / expiresAt / accessUntil all set).
--   * Nobody but the database owner can read or write grants (RLS on, no grants to
--     public / anon / authenticated). Use set_internal_pro / revoke_internal_pro below.
--   * A grant row is removed with its Auth user (on delete cascade).
begin;

do $$
declare
  target_schema text;
begin
  foreach target_schema in array array['mora_prod_private', 'mora_stage_private']
  loop
    execute format($ddl$
      create table if not exists %I.internal_pro_grants (
        user_id uuid primary key references auth.users(id) on delete cascade,
        note text not null check (char_length(btrim(note)) between 1 and 200),
        granted_at timestamptz not null default clock_timestamp(),
        expires_at timestamptz not null default clock_timestamp() + interval '5 years',
        updated_at timestamptz not null default clock_timestamp(),
        check (expires_at > granted_at)
      )
    $ddl$, target_schema);

    execute format('alter table %I.internal_pro_grants enable row level security', target_schema);
    execute format('revoke all on table %I.internal_pro_grants from public, anon, authenticated', target_schema);
  end loop;
end;
$$;

-- is_pro: a real entitlement wins; otherwise an unexpired internal grant counts.
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

  if coalesce(v_is_pro, false) then
    return true;
  end if;

  execute format(
    'select exists (select 1 from %I.internal_pro_grants where user_id = $1 and expires_at > $2)',
    p_schema
  ) into v_is_pro using p_user_id, p_at;

  return coalesce(v_is_pro, false);
end;
$$;

-- mora_get_entitlement: same payload as before, plus the grant fallback.
-- The grant is reported as a yearly subscription because the app rejects an active
-- entitlement whose productId is missing or unknown.
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
  v_grant_granted_at timestamptz;
  v_grant_expires_at timestamptz;
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

  if not (v_status in ('active', 'grace') and v_access_until > clock_timestamp()) then
    execute format(
      'select granted_at, expires_at from %I.internal_pro_grants where user_id = $1 and expires_at > clock_timestamp()',
      v_schema
    ) into v_grant_granted_at, v_grant_expires_at using v_user_id;

    if v_grant_expires_at is not null then
      return jsonb_build_object(
        'isPro', true,
        'status', 'active',
        'productId', 'com.TRIDENT.ADHD.yearly',
        'verifiedAt', v_grant_granted_at,
        'expiresAt', v_grant_expires_at,
        'graceExpiresAt', null,
        'accessUntil', v_grant_expires_at
      );
    end if;
  end if;

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

revoke all on function public.mora_get_entitlement() from public, anon;
grant execute on function public.mora_get_entitlement() to authenticated;

-- Operator helpers (database owner only). They pick the right environment schema.
create or replace function mora_internal.set_internal_pro(
  p_user_id uuid,
  p_note text,
  p_expires_at timestamptz default null
)
returns timestamptz
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_schema text;
  v_expires_at timestamptz := coalesce(p_expires_at, clock_timestamp() + interval '5 years');
begin
  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'unknown_user' using errcode = '22023';
  end if;
  -- resolve_environment only answers for the signed-in caller, so read the binding
  -- directly. An account that has not been bound yet is routed to production, the same
  -- default resolve_environment applies.
  v_schema := mora_internal.schema_for_environment(coalesce(
    (select environment from mora_internal.account_environment where user_id = p_user_id),
    'production'
  ));
  execute format($sql$
    insert into %I.internal_pro_grants (user_id, note, expires_at)
    values ($1, $2, $3)
    on conflict (user_id) do update set
      note = excluded.note,
      expires_at = excluded.expires_at,
      updated_at = clock_timestamp()
  $sql$, v_schema) using p_user_id, p_note, v_expires_at;
  return v_expires_at;
end;
$$;

create or replace function mora_internal.revoke_internal_pro(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_schema text;
  v_deleted integer;
begin
  v_schema := mora_internal.schema_for_environment(coalesce(
    (select environment from mora_internal.account_environment where user_id = p_user_id),
    'production'
  ));
  execute format('delete from %I.internal_pro_grants where user_id = $1', v_schema) using p_user_id;
  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end;
$$;

revoke all on function mora_internal.set_internal_pro(uuid, text, timestamptz) from public, anon, authenticated;
revoke all on function mora_internal.revoke_internal_pro(uuid) from public, anon, authenticated;

commit;
