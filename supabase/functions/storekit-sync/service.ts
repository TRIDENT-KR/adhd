// 앱이 구매·복원 직후 보내는 StoreKit 2 거래 JWS를 검증해 현재 Mora 계정에 귀속한다.
// 인증·서명 검증·DB 호출은 주입받아 테스트에서 가짜로 바꿀 수 있다.
import {
  TransactionFacts,
  TransactionRejected,
  transactionFacts,
} from "../_shared/storekit-facts.ts";

export type SyncAction = "register" | "rebind";

export interface SyncDeps {
  /** Authorization 헤더로 Supabase 사용자를 확인한다. 실패하면 null. */
  authenticate(authorization: string): Promise<string | null>;
  /** Apple 서명·체인 검증을 통과한 payload를 돌려준다. 실패하면 던진다. */
  verifyTransaction(jws: string): Promise<Record<string, unknown>>;
  /** mora_storekit_apply_transaction. DB 예외 메시지는 DatabaseRejected로 던진다. */
  applyTransaction(userId: string, action: SyncAction, facts: TransactionFacts): Promise<string>;
  now(): Date;
}

/** DB 함수가 raise한 예외. message가 곧 오류 코드다. */
export class DatabaseRejected extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "DatabaseRejected";
  }
}

const MAX_JWS_LENGTH = 16_384;

/** DB 예외 코드 → HTTP 상태. 목록에 없는 DB 오류는 일시 장애(503)로 본다. */
const DATABASE_ERROR_STATUS: Record<string, number> = {
  subscription_owned_by_another_account: 409,
  rebind_not_eligible: 409,
  app_account_token_mismatch: 409,
  account_deletion_pending: 409,
  environment_unbound: 409,
  app_account_token_missing: 409,
  apple_environment_not_allowed: 403,
  unknown_product: 422,
  invalid_transaction_id: 422,
  invalid_subscription_state: 422,
  invalid_apple_environment: 422,
};

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function failure(status: number, code: string): Response {
  return json(status, { error: { code } });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function handleSync(req: Request, deps: SyncDeps): Promise<Response> {
  if (req.method !== "POST") return failure(405, "method_not_allowed");

  const authorization = req.headers.get("Authorization");
  if (!authorization) return failure(401, "missing_authorization");
  const userId = await deps.authenticate(authorization);
  if (!userId) return failure(401, "unauthorized");

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return failure(400, "invalid_request_body");
  }
  if (!isRecord(body)) return failure(400, "invalid_request_body");
  const action = body.action;
  const jws = body.signedTransaction;
  if (action !== "register" && action !== "rebind") return failure(400, "invalid_action");
  if (typeof jws !== "string" || jws.length === 0 || jws.length > MAX_JWS_LENGTH) {
    return failure(400, "invalid_signed_transaction");
  }

  let payload: Record<string, unknown>;
  try {
    payload = await deps.verifyTransaction(jws);
  } catch {
    return failure(422, "transaction_signature_invalid");
  }

  let facts: TransactionFacts;
  try {
    facts = transactionFacts(payload, undefined, { now: deps.now() });
  } catch (error) {
    if (error instanceof TransactionRejected) return failure(422, error.code);
    throw error;
  }

  try {
    const result = await deps.applyTransaction(userId, action, facts);
    return json(200, { result });
  } catch (error) {
    if (error instanceof DatabaseRejected) {
      const status = DATABASE_ERROR_STATUS[error.code];
      if (status) return failure(status, error.code);
      console.error("storekit_sync_database_failure", { code: error.code });
      return failure(503, "subscription_backend_unavailable");
    }
    console.error("storekit_sync_unexpected_failure", { action });
    return failure(503, "subscription_backend_unavailable");
  }
}
