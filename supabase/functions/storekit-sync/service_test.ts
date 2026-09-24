import { assertEquals } from "jsr:@std/assert@1";
import { verifyAppleJws } from "../_shared/apple-jws.ts";
import type { TransactionFacts } from "../_shared/storekit-facts.ts";
import { appleLikeChain, sampleTransaction, signJws } from "../_shared/test-pki.ts";
import { DatabaseRejected, handleSync, type SyncAction, type SyncDeps } from "./service.ts";

const NOW = new Date("2026-09-24T09:00:00Z");
const USER = "11111111-2222-4333-8444-555555555555";

type Call = { userId: string; action: SyncAction; facts: TransactionFacts };

function deps(over: Partial<SyncDeps> = {}, calls: Call[] = []): SyncDeps {
  return {
    authenticate: (authorization) =>
      Promise.resolve(authorization === "Bearer good" ? USER : null),
    verifyTransaction: (jws) =>
      jws === "valid.jws"
        ? Promise.resolve(sampleTransaction())
        : Promise.reject(new Error("bad signature")),
    applyTransaction: (userId, action, facts) => {
      calls.push({ userId, action, facts });
      return Promise.resolve("bound");
    },
    now: () => NOW,
    ...over,
  };
}

function request(body: unknown, authorization: string | null = "Bearer good"): Request {
  const headers = new Headers({ "Content-Type": "application/json" });
  if (authorization) headers.set("Authorization", authorization);
  return new Request("https://example.test/storekit-sync", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function call(req: Request, d: SyncDeps) {
  const response = await handleSync(req, d);
  return { status: response.status, body: await response.json() };
}

Deno.test("인증이 없거나 틀리면 401", async () => {
  const body = { action: "register", signedTransaction: "valid.jws" };
  assertEquals((await call(request(body, null), deps())).status, 401);
  assertEquals((await call(request(body, "Bearer bad"), deps())).status, 401);
});

Deno.test("요청 형식이 틀리면 400", async () => {
  assertEquals((await call(request("{not json"), deps())).body.error.code, "invalid_request_body");
  assertEquals(
    (await call(request({ action: "transfer", signedTransaction: "valid.jws" }), deps())).body.error.code,
    "invalid_action",
  );
  assertEquals(
    (await call(request({ action: "register", signedTransaction: "x".repeat(20_000) }), deps())).body.error.code,
    "invalid_signed_transaction",
  );
});

Deno.test("Apple 서명 검증에 실패하면 DB를 부르지 않고 422", async () => {
  const calls: Call[] = [];
  const result = await call(request({ action: "register", signedTransaction: "forged.jws" }), deps({}, calls));
  assertEquals(result.status, 422);
  assertEquals(result.body.error.code, "transaction_signature_invalid");
  assertEquals(calls.length, 0);
});

Deno.test("가족 공유 거래는 권한을 주지 않는다", async () => {
  const calls: Call[] = [];
  const d = deps({
    verifyTransaction: () => Promise.resolve(sampleTransaction({ inAppOwnershipType: "FAMILY_SHARED" })),
  }, calls);
  const result = await call(request({ action: "register", signedTransaction: "valid.jws" }), d);
  assertEquals(result.status, 422);
  assertEquals(result.body.error.code, "family_sharing_not_supported");
  assertEquals(calls.length, 0);
});

Deno.test("검증된 거래를 현재 사용자에게 등록한다", async () => {
  const calls: Call[] = [];
  const result = await call(request({ action: "register", signedTransaction: "valid.jws" }), deps({}, calls));
  assertEquals(result, { status: 200, body: { result: "bound" } });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].userId, USER);
  assertEquals(calls[0].action, "register");
  assertEquals(calls[0].facts.originalTransactionId, "2000000999000001");
  assertEquals(calls[0].facts.state, "active");
});

Deno.test("DB의 소유권 거부는 409, 알 수 없는 DB 오류는 503", async () => {
  const owned = deps({
    applyTransaction: () => Promise.reject(new DatabaseRejected("subscription_owned_by_another_account")),
  });
  const result = await call(request({ action: "rebind", signedTransaction: "valid.jws" }), owned);
  assertEquals(result.status, 409);
  assertEquals(result.body.error.code, "subscription_owned_by_another_account");

  const broken = deps({ applyTransaction: () => Promise.reject(new DatabaseRejected("connection reset")) });
  const failed = await call(request({ action: "register", signedTransaction: "valid.jws" }), broken);
  assertEquals(failed.status, 503);
  assertEquals(failed.body.error.code, "subscription_backend_unavailable");
});

Deno.test("통합: 실제 서명 검증기 + 테스트 체인으로 서명한 거래", async () => {
  const chain = await appleLikeChain();
  const now = new Date();
  const payload = sampleTransaction({
    purchaseDate: now.getTime() - 60_000,
    expiresDate: now.getTime() + 86_400_000,
  });
  const jws = await signJws(payload, chain);
  const calls: Call[] = [];
  const d = deps({
    verifyTransaction: (value) =>
      verifyAppleJws(value, { pinnedRootsDer: [chain.rootDer], expectedBundleId: "trident-KR.ADHD" }),
    now: () => now,
  }, calls);

  const ok = await call(request({ action: "register", signedTransaction: jws }), d);
  assertEquals(ok.status, 200);
  assertEquals(calls[0].facts.state, "active");

  // 서명 뒤 payload를 바꾸면 거부된다.
  const [header, , signature] = jws.split(".");
  const forgedPayload = btoa(JSON.stringify({ ...payload, productId: "com.TRIDENT.ADHD.yearly" }))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const forged = await call(
    request({ action: "register", signedTransaction: `${header}.${forgedPayload}.${signature}` }),
    d,
  );
  assertEquals(forged.status, 422);
  assertEquals(calls.length, 1);
});
