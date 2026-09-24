// Apple이 서명한 거래·갱신 정보를 서버 원장이 저장하는 사실로 바꾼다.
// 서명 검증(apple-jws.ts)을 통과한 payload만 여기에 들어온다.

export const APP_BUNDLE_ID = Deno.env.get("APPLE_BUNDLE_ID") ?? "trident-KR.ADHD";

export const SUBSCRIPTION_PRODUCT_IDS = new Set([
  "com.TRIDENT.ADHD.monthly",
  "com.TRIDENT.ADHD.yearly",
]);

export type AppleEnvironment = "Sandbox" | "Production";

export type SubscriptionState =
  | "active"
  | "grace"
  | "billing_retry"
  | "expired"
  | "revoked"
  | "refunded";

export interface TransactionFacts {
  appleEnvironment: AppleEnvironment;
  originalTransactionId: string;
  transactionId: string;
  appAccountToken: string | null;
  productId: string;
  state: SubscriptionState;
  purchasedAt: string | null;
  expiresAt: string | null;
  graceExpiresAt: string | null;
  revokedAt: string | null;
}

/** 우리 구독 상품의 거래가 아니거나 형식이 어긋나면 던진다. code는 응답에 그대로 쓴다. */
export class TransactionRejected extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "TransactionRejected";
  }
}

const NUMERIC_ID = /^[0-9]{1,40}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function millis(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : null;
}

function iso(ms: number | null): string | null {
  return ms === null ? null : new Date(ms).toISOString();
}

/**
 * 거래 하나와 (있다면) 갱신 정보로 현재 구독 상태를 정한다.
 * - 환불·취소 기록이 있으면 권한 없음
 * - 만료 전이면 active
 * - 결제 재시도 중이고 유예 기간이 남아 있으면 grace (INT-15: 명시적 유예만 Pro)
 * - 결제 재시도 중이면 billing_retry, 아니면 expired
 */
export function deriveState(
  transaction: Record<string, unknown>,
  renewalInfo: Record<string, unknown> | undefined,
  notificationType: string | undefined,
  now: Date,
): SubscriptionState {
  if (notificationType === "REVOKE") return "revoked";
  if (millis(transaction.revocationDate) !== null) return "refunded";

  const nowMs = now.getTime();
  const expires = millis(transaction.expiresDate);
  if (expires !== null && expires > nowMs) return "active";

  const inBillingRetry = renewalInfo?.isInBillingRetryPeriod === true;
  const graceExpires = millis(renewalInfo?.gracePeriodExpiresDate);
  if (inBillingRetry && graceExpires !== null && graceExpires > nowMs) return "grace";
  if (inBillingRetry) return "billing_retry";
  return "expired";
}

export function transactionFacts(
  transaction: Record<string, unknown>,
  renewalInfo: Record<string, unknown> | undefined,
  options: { now: Date; notificationType?: string },
): TransactionFacts {
  if (transaction.bundleId !== APP_BUNDLE_ID) throw new TransactionRejected("bundle_mismatch");
  if (transaction.type !== "Auto-Renewable Subscription") {
    throw new TransactionRejected("not_a_subscription");
  }
  if (typeof transaction.productId !== "string" || !SUBSCRIPTION_PRODUCT_IDS.has(transaction.productId)) {
    throw new TransactionRejected("unknown_product");
  }
  // v1은 가족 공유를 지원하지 않는다.
  if (transaction.inAppOwnershipType !== "PURCHASED") {
    throw new TransactionRejected("family_sharing_not_supported");
  }
  const environment = transaction.environment;
  if (environment !== "Sandbox" && environment !== "Production") {
    throw new TransactionRejected("unsupported_environment");
  }
  const originalTransactionId = transaction.originalTransactionId;
  const transactionId = transaction.transactionId;
  if (
    typeof originalTransactionId !== "string" || !NUMERIC_ID.test(originalTransactionId) ||
    typeof transactionId !== "string" || !NUMERIC_ID.test(transactionId)
  ) {
    throw new TransactionRejected("invalid_transaction_id");
  }
  const expiresAt = millis(transaction.expiresDate);
  if (expiresAt === null) throw new TransactionRejected("missing_expiration");

  const token = transaction.appAccountToken;
  if (token !== undefined && token !== null && (typeof token !== "string" || !UUID.test(token))) {
    throw new TransactionRejected("invalid_app_account_token");
  }
  if (renewalInfo !== undefined) {
    if (renewalInfo.environment !== environment) throw new TransactionRejected("environment_mismatch");
    if (
      renewalInfo.originalTransactionId !== undefined &&
      renewalInfo.originalTransactionId !== originalTransactionId
    ) {
      throw new TransactionRejected("renewal_info_mismatch");
    }
  }

  const state = deriveState(transaction, renewalInfo, options.notificationType, options.now);
  return {
    appleEnvironment: environment,
    originalTransactionId,
    transactionId,
    appAccountToken: typeof token === "string" ? token.toLowerCase() : null,
    productId: transaction.productId,
    state,
    purchasedAt: iso(millis(transaction.purchaseDate)),
    expiresAt: iso(expiresAt),
    graceExpiresAt: state === "grace" ? iso(millis(renewalInfo?.gracePeriodExpiresDate)) : null,
    revokedAt: iso(millis(transaction.revocationDate)),
  };
}
