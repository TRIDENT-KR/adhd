import { assertEquals } from "jsr:@std/assert@1";
import { verifyAppleJws } from "../_shared/apple-jws.ts";
import type { TransactionFacts } from "../_shared/storekit-facts.ts";
import {
  appleLikeChain,
  sampleTransaction,
  signJws,
} from "../_shared/test-pki.ts";
import {
  DatabaseRejected,
  handleSync,
  type SyncAction,
  type SyncDeps,
} from "./service.ts";

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

function request(
  body: unknown,
  authorization: string | null = "Bearer good",
): Request {
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
  assertEquals(
    (await call(request("{not json"), deps())).body.error.code,
    "invalid_request_body",
  );
  assertEquals(
    (await call(
      request({ action: "transfer", signedTransaction: "valid.jws" }),
      deps(),
    )).body.error.code,
    "invalid_action",
  );
  assertEquals(
    (await call(
      request({ action: "register", signedTransaction: "x".repeat(20_000) }),
      deps(),
    )).body.error.code,
    "invalid_signed_transaction",
  );
});

Deno.test("Apple 서명 검증에 실패하면 DB를 부르지 않고 422", async () => {
  const calls: Call[] = [];
  const result = await call(
    request({ action: "register", signedTransaction: "forged.jws" }),
    deps({}, calls),
  );
  assertEquals(result.status, 422);
  assertEquals(result.body.error.code, "transaction_signature_invalid");
  assertEquals(calls.length, 0);
});

Deno.test("가족 공유 거래는 권한을 주지 않는다", async () => {
  const calls: Call[] = [];
  const d = deps({
    verifyTransaction: () =>
      Promise.resolve(
        sampleTransaction({ inAppOwnershipType: "FAMILY_SHARED" }),
      ),
  }, calls);
  const result = await call(
    request({ action: "register", signedTransaction: "valid.jws" }),
    d,
  );
  assertEquals(result.status, 422);
  assertEquals(result.body.error.code, "family_sharing_not_supported");
  assertEquals(calls.length, 0);
});

Deno.test("검증된 거래를 현재 사용자에게 등록한다", async () => {
  const calls: Call[] = [];
  const result = await call(
    request({ action: "register", signedTransaction: "valid.jws" }),
    deps({}, calls),
  );
  assertEquals(result, { status: 200, body: { result: "bound" } });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].userId, USER);
  assertEquals(calls[0].action, "register");
  assertEquals(calls[0].facts.originalTransactionId, "2000000999000001");
  assertEquals(calls[0].facts.state, "active");
});

Deno.test("DB의 소유권 거부는 409, 알 수 없는 DB 오류는 503", async () => {
  const owned = deps({
    applyTransaction: () =>
      Promise.reject(
        new DatabaseRejected("subscription_owned_by_another_account"),
      ),
  });
  const result = await call(
    request({ action: "rebind", signedTransaction: "valid.jws" }),
    owned,
  );
  assertEquals(result.status, 409);
  assertEquals(result.body.error.code, "subscription_owned_by_another_account");

  const broken = deps({
    applyTransaction: () =>
      Promise.reject(new DatabaseRejected("connection reset")),
  });
  const failed = await call(
    request({ action: "register", signedTransaction: "valid.jws" }),
    broken,
  );
  assertEquals(failed.status, 503);
  assertEquals(failed.body.error.code, "subscription_backend_unavailable");
});

Deno.test("claim: 검증된 거래를 claim 모드로 DB에 전달하고 응답 형태는 register와 같다", async () => {
  const calls: Call[] = [];
  const d = deps({
    applyTransaction: (userId, action, facts) => {
      calls.push({ userId, action, facts });
      return Promise.resolve("claimed");
    },
  });
  const result = await call(
    request({ action: "claim", signedTransaction: "valid.jws" }),
    d,
  );
  assertEquals(result, { status: 200, body: { result: "claimed" } });
  assertEquals(calls.length, 1);
  assertEquals(calls[0].userId, USER);
  assertEquals(calls[0].action, "claim");
  // 토큰은 다른(이전) 계정 것이어도 그대로 전달한다. 비교 여부는 DB가 mode로 정한다.
  assertEquals(
    calls[0].facts.appAccountToken,
    "6f9619ff-8b86-d011-b42d-00c04fc964ff",
  );
});

Deno.test("claim도 Apple 서명·번들·환경 검증에 실패하면 DB를 부르지 않는다", async () => {
  const calls: Call[] = [];
  const forged = await call(
    request({ action: "claim", signedTransaction: "forged.jws" }),
    deps({}, calls),
  );
  assertEquals(forged.status, 422);
  assertEquals(forged.body.error.code, "transaction_signature_invalid");

  for (
    const [over, code] of [
      [{ bundleId: "com.example.other" }, "bundle_mismatch"],
      [{ environment: "Xcode" }, "unsupported_environment"],
      [{ inAppOwnershipType: "FAMILY_SHARED" }, "family_sharing_not_supported"],
    ] as const
  ) {
    const rejected = await call(
      request({ action: "claim", signedTransaction: "valid.jws" }),
      deps({
        verifyTransaction: () => Promise.resolve(sampleTransaction(over)),
      }, calls),
    );
    assertEquals(rejected.status, 422);
    assertEquals(rejected.body.error.code, code);
  }
  assertEquals(calls.length, 0);
});

Deno.test("claim_not_active는 409, 다른 claim 거부 코드도 그대로 매핑한다", async () => {
  for (
    const [code, status] of [
      ["claim_not_active", 409],
      ["apple_environment_not_allowed", 403],
      ["account_deletion_pending", 409],
    ] as const
  ) {
    const result = await call(
      request({ action: "claim", signedTransaction: "valid.jws" }),
      deps({
        applyTransaction: () => Promise.reject(new DatabaseRejected(code)),
      }),
    );
    assertEquals(result.status, status);
    assertEquals(result.body.error.code, code);
  }
});

Deno.test("통합: 실제 서명 검증기 + 테스트 체인으로 서명한 거래", async () => {
  const chain = await appleLikeChain();
  const now = new Date();
  const payload = sampleTransaction({
    purchaseDate: now.getTime() - 60_000,
    expiresDate: now.getTime() + 86_400_000,
    signedDate: now.getTime(),
  });
  const jws = await signJws(payload, chain);
  const calls: Call[] = [];
  const d = deps({
    verifyTransaction: (value) =>
      verifyAppleJws(value, {
        pinnedRootsDer: [chain.rootDer],
        expectedBundleId: "trident-KR.ADHD",
      }),
    now: () => now,
  }, calls);

  const ok = await call(
    request({ action: "register", signedTransaction: jws }),
    d,
  );
  assertEquals(ok.status, 200);
  assertEquals(calls[0].facts.state, "active");

  // 서명 뒤 payload를 바꾸면 거부된다.
  const [header, , signature] = jws.split(".");
  const forgedPayload = btoa(
    JSON.stringify({ ...payload, productId: "com.TRIDENT.ADHD.yearly" }),
  )
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const forged = await call(
    request({
      action: "register",
      signedTransaction: `${header}.${forgedPayload}.${signature}`,
    }),
    d,
  );
  assertEquals(forged.status, 422);
  assertEquals(calls.length, 1);
});

Deno.test("앱의 별도 signedDate 필드는 신뢰하지 않고 검증된 JWS 시각만 전달한다", async () => {
  const calls: Call[] = [];
  const result = await call(
    request({
      action: "register",
      signedTransaction: "valid.jws",
      signedDate: NOW.getTime() + 86400000,
    }),
    deps({}, calls),
  );
  assertEquals(result.status, 200);
  assertEquals(calls[0].facts.signedAt, NOW.toISOString());
});

Deno.test("서명은 맞아도 signedDate 없는 거래는 DB에 전달하지 않는다", async () => {
  const calls: Call[] = [];
  const result = await call(
    request({ action: "register", signedTransaction: "valid.jws" }),
    deps({
      verifyTransaction: () =>
        Promise.resolve(sampleTransaction({ signedDate: undefined })),
    }, calls),
  );
  assertEquals(result.status, 422);
  assertEquals(result.body.error.code, "invalid_signed_date");
  assertEquals(calls.length, 0);
});

Deno.test("통합: claim도 실제 서명 검증기(신뢰 루트·번들)를 통과해야 DB에 닿는다", async () => {
  const chain = await appleLikeChain();
  const untrusted = await appleLikeChain();
  const now = new Date();
  const payload = sampleTransaction({
    purchaseDate: now.getTime() - 60_000,
    expiresDate: now.getTime() + 86_400_000,
    signedDate: now.getTime(),
    // 이전 설치(다른 계정)의 토큰이 붙은 거래.
    appAccountToken: "0f0e0d0c-0b0a-4908-8706-050403020100",
  });
  const calls: Call[] = [];
  const d = deps({
    verifyTransaction: (value) =>
      verifyAppleJws(value, {
        pinnedRootsDer: [chain.rootDer],
        expectedBundleId: "trident-KR.ADHD",
      }),
    now: () => now,
  }, calls);

  const ok = await call(
    request({
      action: "claim",
      signedTransaction: await signJws(payload, chain),
    }),
    d,
  );
  assertEquals(ok.status, 200);
  assertEquals(calls[0].action, "claim");
  assertEquals(
    calls[0].facts.appAccountToken,
    "0f0e0d0c-0b0a-4908-8706-050403020100",
  );

  const otherRoot = await call(
    request({
      action: "claim",
      signedTransaction: await signJws(payload, untrusted),
    }),
    d,
  );
  const otherApp = await call(
    request({
      action: "claim",
      signedTransaction: await signJws(
        { ...payload, bundleId: "com.example.other" },
        chain,
      ),
    }),
    d,
  );
  assertEquals(otherRoot.status, 422);
  assertEquals(otherApp.status, 422);
  assertEquals(otherApp.body.error.code, "transaction_signature_invalid");
  assertEquals(calls.length, 1);
});
