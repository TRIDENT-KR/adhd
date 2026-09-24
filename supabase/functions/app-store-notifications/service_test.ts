import { assertEquals } from "jsr:@std/assert@1";
import { verifyAppleNotification } from "../_shared/apple-jws.ts";
import { appleLikeChain, sampleTransaction, signJws } from "../_shared/test-pki.ts";
import {
  handleNotification,
  type NotificationDeps,
  type NotificationRecord,
  type VerifiedNotification,
} from "./service.ts";

const NOW = new Date("2026-09-24T09:00:00Z");
const HOUR = 3_600_000;
const NOTIFICATION_UUID = "0F2A7C1E-5B6D-4E8F-9A0B-1C2D3E4F5A6B";

function verified(over: {
  notification?: Record<string, unknown>;
  transaction?: Record<string, unknown> | null;
  renewalInfo?: Record<string, unknown>;
} = {}): VerifiedNotification {
  return {
    notification: {
      notificationType: "DID_RENEW",
      notificationUUID: NOTIFICATION_UUID,
      data: { bundleId: "trident-KR.ADHD", environment: "Sandbox" },
      ...over.notification,
    },
    transaction: over.transaction === null ? undefined : over.transaction ?? sampleTransaction(),
    renewalInfo: over.renewalInfo,
  };
}

function deps(
  result: VerifiedNotification | Error,
  records: NotificationRecord[] = [],
  apply: () => Promise<string> = () => Promise.resolve("updated"),
): NotificationDeps {
  return {
    verifyNotification: () => result instanceof Error ? Promise.reject(result) : Promise.resolve(result),
    applyNotification: (record) => {
      records.push(record);
      return apply();
    },
    expectedBundleId: "trident-KR.ADHD",
    now: () => NOW,
  };
}

function request(body: unknown = { signedPayload: "signed.payload.value" }): Request {
  return new Request("https://example.test/app-store-notifications", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function call(req: Request, d: NotificationDeps) {
  const response = await handleNotification(req, d);
  return { status: response.status, body: await response.json() };
}

Deno.test("서명이 틀린 알림은 400이고 DB에 닿지 않는다", async () => {
  const records: NotificationRecord[] = [];
  const result = await call(request(), deps(new Error("bad"), records));
  assertEquals(result.status, 400);
  assertEquals(records.length, 0);
});

Deno.test("갱신 알림은 active 사실로 반영한다", async () => {
  const records: NotificationRecord[] = [];
  const result = await call(request(), deps(verified(), records));
  assertEquals(result, { status: 200, body: { result: "updated" } });
  assertEquals(records[0].notificationUUID, NOTIFICATION_UUID.toLowerCase());
  assertEquals(records[0].facts?.state, "active");
});

Deno.test("유예 기간 결제 실패 알림은 grace", async () => {
  const records: NotificationRecord[] = [];
  const v = verified({
    notification: {
      notificationType: "DID_FAIL_TO_RENEW",
      subtype: "GRACE_PERIOD",
      notificationUUID: NOTIFICATION_UUID,
      data: { bundleId: "trident-KR.ADHD", environment: "Sandbox" },
    },
    transaction: sampleTransaction({ expiresDate: NOW.getTime() - HOUR }),
    renewalInfo: {
      environment: "Sandbox",
      isInBillingRetryPeriod: true,
      gracePeriodExpiresDate: NOW.getTime() + 6 * 24 * HOUR,
    },
  });
  await call(request(), deps(v, records));
  assertEquals(records[0].subtype, "GRACE_PERIOD");
  assertEquals(records[0].facts?.state, "grace");
});

Deno.test("환불 알림은 refunded", async () => {
  const records: NotificationRecord[] = [];
  const v = verified({
    notification: {
      notificationType: "REFUND",
      notificationUUID: NOTIFICATION_UUID,
      data: { bundleId: "trident-KR.ADHD", environment: "Sandbox" },
    },
    transaction: sampleTransaction({ revocationDate: NOW.getTime() - 60_000, revocationReason: 0 }),
  });
  await call(request(), deps(v, records));
  assertEquals(records[0].facts?.state, "refunded");
});

Deno.test("다른 앱 알림은 200으로 무시하고, 가족 공유·TEST 알림은 기록만 한다", async () => {
  const records: NotificationRecord[] = [];
  const otherApp = verified({
    notification: {
      notificationType: "DID_RENEW",
      notificationUUID: NOTIFICATION_UUID,
      data: { bundleId: "com.other.app", environment: "Sandbox" },
    },
  });
  assertEquals((await call(request(), deps(otherApp, records))).body.result, "ignored_other_app");
  assertEquals(records.length, 0);

  const family = verified({ transaction: sampleTransaction({ inAppOwnershipType: "FAMILY_SHARED" }) });
  assertEquals((await call(request(), deps(family, records))).status, 200);
  assertEquals(records[0].facts, null);

  const test = verified({
    notification: {
      notificationType: "TEST",
      notificationUUID: NOTIFICATION_UUID,
      data: { bundleId: "trident-KR.ADHD", environment: "Sandbox" },
    },
    transaction: null,
  });
  assertEquals((await call(request(), deps(test, records))).status, 200);
  assertEquals(records[1].facts, null);
});

Deno.test("알림 환경과 거래 환경이 다르면 400", async () => {
  const v = verified({ transaction: sampleTransaction({ environment: "Production" }) });
  assertEquals((await call(request(), deps(v))).body.error.code, "environment_mismatch");
});

Deno.test("DB 장애면 503을 돌려 Apple이 다시 보내게 한다", async () => {
  const result = await call(request(), deps(verified(), [], () => Promise.reject(new Error("down"))));
  assertEquals(result.status, 503);
});

Deno.test("통합: 테스트 체인으로 서명한 실제 V2 알림(중첩 JWS 포함)", async () => {
  const chain = await appleLikeChain();
  const now = new Date();
  const signedTransactionInfo = await signJws(
    sampleTransaction({ purchaseDate: now.getTime() - HOUR, expiresDate: now.getTime() + HOUR }),
    chain,
  );
  const signedRenewalInfo = await signJws(
    { environment: "Sandbox", originalTransactionId: "2000000999000001", autoRenewStatus: 1 },
    chain,
  );
  const signedPayload = await signJws({
    notificationType: "SUBSCRIBED",
    subtype: "INITIAL_BUY",
    notificationUUID: NOTIFICATION_UUID,
    version: "2.0",
    signedDate: now.getTime(),
    data: {
      bundleId: "trident-KR.ADHD",
      environment: "Sandbox",
      signedTransactionInfo,
      signedRenewalInfo,
    },
  }, chain);

  const records: NotificationRecord[] = [];
  const d: NotificationDeps = {
    verifyNotification: (value) => verifyAppleNotification(value, { pinnedRootsDer: [chain.rootDer] }),
    applyNotification: (record) => {
      records.push(record);
      return Promise.resolve("bound");
    },
    expectedBundleId: "trident-KR.ADHD",
    now: () => now,
  };
  const result = await call(request({ signedPayload }), d);
  assertEquals(result, { status: 200, body: { result: "bound" } });
  assertEquals(records[0].facts?.appAccountToken, "6f9619ff-8b86-d011-b42d-00c04fc964ff");

  // 다른 루트로 만든 체인이면 거부
  const attacker = await appleLikeChain();
  const forged = await signJws({ notificationType: "SUBSCRIBED", data: {} }, attacker);
  assertEquals((await call(request({ signedPayload: forged }), d)).status, 400);
});
