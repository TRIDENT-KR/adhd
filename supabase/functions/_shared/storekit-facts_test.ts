import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { deriveState, TransactionRejected, transactionFacts } from "./storekit-facts.ts";
import { SAMPLE_NOW as NOW, sampleTransaction } from "./test-pki.ts";

const HOUR = 3_600_000;

Deno.test("유효한 구독 거래는 active 사실로 바뀐다", () => {
  const facts = transactionFacts(sampleTransaction(), undefined, { now: NOW });
  assertEquals(facts.state, "active");
  assertEquals(facts.appleEnvironment, "Sandbox");
  assertEquals(facts.appAccountToken, "6f9619ff-8b86-d011-b42d-00c04fc964ff");
  assertEquals(facts.graceExpiresAt, null);
});

Deno.test("우리 앱·상품·구매 형태가 아니면 거부한다", () => {
  const cases: [Record<string, unknown>, string][] = [
    [{ bundleId: "com.other.app" }, "bundle_mismatch"],
    [{ productId: "com.TRIDENT.ADHD.lifetime" }, "unknown_product"],
    [{ type: "Non-Consumable" }, "not_a_subscription"],
    [{ inAppOwnershipType: "FAMILY_SHARED" }, "family_sharing_not_supported"],
    [{ environment: "Xcode" }, "unsupported_environment"],
    [{ originalTransactionId: "abc" }, "invalid_transaction_id"],
    [{ expiresDate: undefined }, "missing_expiration"],
    [{ appAccountToken: "not-a-uuid" }, "invalid_app_account_token"],
  ];
  for (const [over, code] of cases) {
    const error = assertThrows(
      () => transactionFacts(sampleTransaction(over), undefined, { now: NOW }),
      TransactionRejected,
    );
    assertEquals(error.code, code);
  }
});

Deno.test("갱신 정보가 다른 환경·다른 거래면 거부한다", () => {
  assertThrows(
    () => transactionFacts(sampleTransaction(), { environment: "Production" }, { now: NOW }),
    TransactionRejected,
    "environment_mismatch",
  );
  assertThrows(
    () =>
      transactionFacts(
        sampleTransaction(),
        { environment: "Sandbox", originalTransactionId: "1" },
        { now: NOW },
      ),
    TransactionRejected,
    "renewal_info_mismatch",
  );
});

Deno.test("상태 판정: 만료·유예·결제 재시도·환불·취소", () => {
  const expired = sampleTransaction({ expiresDate: NOW.getTime() - HOUR });
  assertEquals(deriveState(expired, undefined, undefined, NOW), "expired");
  assertEquals(
    deriveState(expired, { isInBillingRetryPeriod: true, gracePeriodExpiresDate: NOW.getTime() + HOUR }, undefined, NOW),
    "grace",
  );
  // 유예가 끝났으면 재시도 중이어도 Pro가 아니다 (INT-15)
  assertEquals(
    deriveState(expired, { isInBillingRetryPeriod: true, gracePeriodExpiresDate: NOW.getTime() - HOUR }, undefined, NOW),
    "billing_retry",
  );
  assertEquals(
    deriveState(sampleTransaction({ revocationDate: NOW.getTime() - 60_000 }), undefined, undefined, NOW),
    "refunded",
  );
  assertEquals(deriveState(sampleTransaction(), undefined, "REVOKE", NOW), "revoked");
});

Deno.test("grace 상태에서만 유예 만료 시각을 넘긴다", () => {
  const facts = transactionFacts(
    sampleTransaction({ expiresDate: NOW.getTime() - HOUR }),
    { environment: "Sandbox", isInBillingRetryPeriod: true, gracePeriodExpiresDate: NOW.getTime() + HOUR },
    { now: NOW },
  );
  assertEquals(facts.state, "grace");
  assertEquals(facts.graceExpiresAt, new Date(NOW.getTime() + HOUR).toISOString());
});
