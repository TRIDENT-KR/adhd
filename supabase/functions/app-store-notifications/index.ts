import { createClient } from "@supabase/supabase-js";
import {
  APPLE_ROOT_CA_G3_DER_B64,
  base64ToBytes,
  verifyAppleNotification,
} from "../_shared/apple-jws.ts";
import { APP_BUNDLE_ID } from "../_shared/storekit-facts.ts";
import { handleNotification } from "./service.ts";

const PINNED_ROOTS = [base64ToBytes(APPLE_ROOT_CA_G3_DER_B64)];

// Apple이 직접 호출하므로 Supabase JWT가 없다(verify_jwt = false).
// 신뢰는 Apple 서명 체인 검증으로만 얻는다.
Deno.serve(async (req: Request) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return new Response(
      JSON.stringify({ error: { code: "server_not_configured" } }),
      { status: 503, headers: { "Content-Type": "application/json" } },
    );
  }
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return await handleNotification(req, {
    verifyNotification: (signedPayload) =>
      verifyAppleNotification(signedPayload, { pinnedRootsDer: PINNED_ROOTS }),
    applyNotification: async (record) => {
      const facts = record.facts;
      const { data, error } = await admin.rpc("mora_storekit_apply_notification", {
        p_notification_uuid: record.notificationUUID,
        p_notification_type: record.notificationType,
        p_subtype: record.subtype,
        p_apple_environment: record.appleEnvironment,
        p_original_transaction_id: facts?.originalTransactionId ?? null,
        p_transaction_id: facts?.transactionId ?? null,
        p_app_account_token: facts?.appAccountToken ?? null,
        p_product_id: facts?.productId ?? null,
        p_state: facts?.state ?? null,
        p_purchased_at: facts?.purchasedAt ?? null,
        p_expires_at: facts?.expiresAt ?? null,
        p_grace_expires_at: facts?.graceExpiresAt ?? null,
        p_revoked_at: facts?.revokedAt ?? null,
      });
      if (error) throw new Error("notification_rpc_failed");
      return typeof data?.result === "string" ? data.result : "recorded";
    },
    expectedBundleId: APP_BUNDLE_ID,
    now: () => new Date(),
  });
});
