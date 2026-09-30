# Account adult eligibility

The launch policy is `adult-v1`: an explicit self-attestation that the person is
18 or older. This records an affirmative answer; it does not verify identity or
date of birth. A local guest answer is separate from the authenticated account
record. A declined answer is retained only on that device; it does not revoke an
existing affirmative server record or propagate a restriction to other devices.
This must not be presented as identity-based, cross-device age enforcement.

## RPC contract

Both RPCs require the authenticated user's JWT. The user ID comes only from
`auth.uid()`; no user ID parameter is accepted. Anonymous and service-role calls
cannot accept on a user's behalf.

| RPC | Parameters | Response |
| --- | --- | --- |
| `get_adult_eligibility` | none | `{"eligible":false,"policyVersion":"adult-v1"}` when absent or outdated; `eligible:true` for the current record |
| `accept_adult_eligibility` | `{"p_policy_version":"adult-v1"}` | `{"eligible":true,"policyVersion":"adult-v1"}` |

Call `accept` only in response to the user's explicit affirmative action. Null,
empty, declined, and unsupported policy values fail with
`unsupported_adult_policy_version`. Both RPCs preserve account environment
binding and reject an account whose deletion is in progress. There is no bulk
backfill or automatic approval of an existing account.

The private RLS-protected table has exactly `user_id`, `policy_version`, and
`accepted_at` (server timestamp). Repeating the same version preserves its first
acceptance time. Accepting a new version replaces the previous record; no history
copy is retained. No date of birth, identity document, IP address, or declined
answer is stored by these server RPCs.

The record references `account_environment` with `ON DELETE CASCADE`. The account
deletion data-purge phase removes that environment row, so the attestation is
already gone even if the later Auth deletion needs a retry. Direct Auth deletion
also cascades through `account_environment`. The attestation has no post-deletion
retention period and is not copied to StoreKit retention records.

## AI and subscription behavior

`analyze-task` authenticates the account, then checks this RPC before parsing the
request text, rate limiting, reserving AI quota, returning a cached result, or
calling Gemini. An absent/outdated record returns:

```json
{"error":{"code":"adult_eligibility_required"},"requestId":null}
```

The status is 403. A lookup failure or malformed response returns 503 with code
`adult_eligibility_unavailable`, with no quota or model side effect. A body field
claiming eligibility has no effect.

StoreKit synchronization, entitlement queries, subscription restoration, and
account deletion remain available without this attestation. `storekit-sync`
registers transactions already charged by Apple, so blocking it would interfere
with existing subscriptions. The compatible iOS app gates a **new purchase**
before calling StoreKit.

## Coordinated release order

1. Apply `202609300002_mora_adult_eligibility.sql` so compatible apps can query and
   save account attestations. This migration alone does not gate the current
   deployed AI function.
2. Make the compatible iOS release with the explicit account confirmation UI
   available. Verify get/accept, account switching, and subscription management
   using the deployed RPCs.
3. Deploy the `analyze-task` function containing the new gate. Old clients without
   the confirmation UI now receive 403 until their account has been affirmed by a
   compatible client. Coordinate this activation with the app rollout.

Do not deploy the gate ahead of the migration or compatible app. This work's
local tests do not constitute remote deployment or verification of an App Store
release. No runtime feature flag is included.

## Offline regressions

`adult-eligibility_test.ts` imports the real Edge entrypoint with `fetch`,
`Deno.serve`, and environment lookup replaced. No real listener, network call,
account, secret, or model API call is used. It checks missing/old policy,
malformed/RPC/network errors, caller claims, cached replay, normal eligible
requests, and failed authentication. Run:

```sh
deno test --config supabase/deno.json --allow-read --allow-env=APPLE_BUNDLE_ID supabase/functions/analyze-task/adult-eligibility_test.ts
```

The local PostgreSQL harness `supabase/tests/db/storekit_db_check.py` also checks
RPC grants, minimal storage, account isolation, rejected values, idempotency,
version refresh, RLS, deletion during purge and direct Auth deletion, plus
restoration and deletion for accounts without attestation. It creates a temporary
cluster and applies every migration twice; it does not contact Supabase.
