// App Store Server Notifications V2 수신. Apple은 200을 받을 때까지 재전송하므로
// 우리 쪽 일시 장애는 503, 우리와 무관하거나 이미 처리한 알림은 200으로 답한다.
import {
  TransactionFacts,
  TransactionRejected,
  transactionFacts,
} from "../_shared/storekit-facts.ts";

export interface VerifiedNotification {
  notification: Record<string, unknown>;
  transaction?: Record<string, unknown>;
  renewalInfo?: Record<string, unknown>;
}

export interface NotificationRecord {
  notificationUUID: string;
  notificationType: string;
  subtype: string | null;
  appleEnvironment: "Sandbox" | "Production";
  facts: TransactionFacts | null;
}

export interface NotificationDeps {
  /** signedPayload와 중첩 JWS를 모두 검증한다. 실패하면 던진다. */
  verifyNotification(signedPayload: string): Promise<VerifiedNotification>;
  /** mora_storekit_apply_notification. 실패하면 던진다. */
  applyNotification(record: NotificationRecord): Promise<string>;
  expectedBundleId: string;
  now(): Date;
}

const MAX_PAYLOAD_LENGTH = 65_536;
const TYPE = /^[A-Z_]{1,64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function handleNotification(req: Request, deps: NotificationDeps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: { code: "method_not_allowed" } });

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: { code: "invalid_request_body" } });
  }
  const signedPayload = isRecord(body) ? body.signedPayload : undefined;
  if (typeof signedPayload !== "string" || signedPayload.length > MAX_PAYLOAD_LENGTH) {
    return json(400, { error: { code: "invalid_request_body" } });
  }

  let verified: VerifiedNotification;
  try {
    verified = await deps.verifyNotification(signedPayload);
  } catch {
    return json(400, { error: { code: "notification_signature_invalid" } });
  }

  const { notification, transaction, renewalInfo } = verified;
  const notificationType = notification.notificationType;
  const subtype = notification.subtype ?? null;
  const notificationUUID = notification.notificationUUID;
  const data = isRecord(notification.data) ? notification.data : undefined;
  const environment = data?.environment;
  if (
    typeof notificationType !== "string" || !TYPE.test(notificationType) ||
    (subtype !== null && (typeof subtype !== "string" || !TYPE.test(subtype))) ||
    typeof notificationUUID !== "string" || !UUID.test(notificationUUID) ||
    (environment !== "Sandbox" && environment !== "Production")
  ) {
    return json(400, { error: { code: "invalid_notification" } });
  }
  // 다른 앱의 알림이면 처리하지 않는다. (서명은 Apple 것이라 재전송을 멈추도록 200)
  if (data?.bundleId !== deps.expectedBundleId) {
    return json(200, { result: "ignored_other_app" });
  }

  let facts: TransactionFacts | null = null;
  if (transaction) {
    if (transaction.environment !== environment) {
      return json(400, { error: { code: "environment_mismatch" } });
    }
    try {
      facts = transactionFacts(transaction, renewalInfo, {
        now: deps.now(),
        notificationType,
      });
    } catch (error) {
      if (!(error instanceof TransactionRejected)) throw error;
      // 가족 공유·다른 상품 등 우리가 권한을 주지 않는 거래. 기록만 남긴다.
      facts = null;
    }
  }

  try {
    const result = await deps.applyNotification({
      notificationUUID: notificationUUID.toLowerCase(),
      notificationType,
      subtype: subtype as string | null,
      appleEnvironment: environment,
      facts,
    });
    console.info("app_store_notification_processed", { notificationType, subtype, result });
    return json(200, { result });
  } catch {
    console.error("app_store_notification_failed", { notificationType, subtype });
    return json(503, { error: { code: "notification_backend_unavailable" } });
  }
}
