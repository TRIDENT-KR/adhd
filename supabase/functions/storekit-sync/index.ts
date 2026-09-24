import { createClient } from "@supabase/supabase-js";
import {
  APPLE_ROOT_CA_G3_DER_B64,
  base64ToBytes,
  verifyAppleJws,
} from "../_shared/apple-jws.ts";
import { APP_BUNDLE_ID } from "../_shared/storekit-facts.ts";
import { DatabaseRejected, handleSync } from "./service.ts";

const PINNED_ROOTS = [base64ToBytes(APPLE_ROOT_CA_G3_DER_B64)];

Deno.serve(async (req: Request) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return new Response(
      JSON.stringify({ error: { code: "server_not_configured" } }),
      { status: 503, headers: { "Content-Type": "application/json" } },
    );
  }
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return await handleSync(req, {
    authenticate: async (authorization) => {
      const client = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: authorization } },
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const { data: { user }, error } = await client.auth.getUser();
      return error || !user ? null : user.id;
    },
    verifyTransaction: (jws) =>
      verifyAppleJws(jws, { pinnedRootsDer: PINNED_ROOTS, expectedBundleId: APP_BUNDLE_ID }),
    applyTransaction: async (userId, action, facts) => {
      const { data, error } = await admin.rpc("mora_storekit_apply_transaction", {
        p_user_id: userId,
        p_mode: action,
        p_apple_environment: facts.appleEnvironment,
        p_original_transaction_id: facts.originalTransactionId,
        p_transaction_id: facts.transactionId,
        p_app_account_token: facts.appAccountToken,
        p_product_id: facts.productId,
        p_state: facts.state,
        p_purchased_at: facts.purchasedAt,
        p_expires_at: facts.expiresAt,
        p_grace_expires_at: facts.graceExpiresAt,
        p_revoked_at: facts.revokedAt,
      });
      if (error) throw new DatabaseRejected(error.message);
      return typeof data?.result === "string" ? data.result : "updated";
    },
    now: () => new Date(),
  });
});
