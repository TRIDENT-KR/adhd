import {
  beginContractMismatch,
  deletionStatusToken,
  isAnonymousBeginRequest,
  isBeginRequest,
  isStatusRequest,
  isVerifiedAnonymousUser,
  parseBeginRequest,
  sha256Hex,
} from "./contract.ts";

const requestId = "6de1e53d-f74b-4cb6-9315-f41a79fc843d";
const token = "a".repeat(43);

Deno.test("begin request accepts only the exact contract", () => {
  if (!isBeginRequest({ requestId, appleAuthorizationCode: "one-time-code" })) {
    throw new Error("valid begin request rejected");
  }
  if (
    isBeginRequest({ requestId, appleAuthorizationCode: "code", extra: true })
  ) {
    throw new Error("unknown begin field accepted");
  }
  if (isBeginRequest({ requestId, appleAuthorizationCode: "" })) {
    throw new Error("empty Apple code accepted");
  }
});

Deno.test("status request accepts only request ID and 43-character secret", () => {
  if (!isStatusRequest({ action: "status", requestId, statusToken: token })) {
    throw new Error("valid status request rejected");
  }
  if (isStatusRequest({ action: "status", requestId, statusToken: "short" })) {
    throw new Error("short status token accepted");
  }
  if (isStatusRequest({ action: "delete", requestId, statusToken: token })) {
    throw new Error("unknown status action accepted");
  }
});

Deno.test("status token is stable for retry and scoped to account", async () => {
  const secret = "0123456789abcdef0123456789abcdef";
  const first = await deletionStatusToken("USER-A", requestId, secret);
  const retry = await deletionStatusToken(
    "user-a",
    requestId.toUpperCase(),
    secret,
  );
  const otherAccount = await deletionStatusToken("user-b", requestId, secret);
  if (first !== retry || first === otherAccount || first.length !== 43) {
    throw new Error("status token scope is invalid");
  }
});

Deno.test("only the token hash needs to be stored", async () => {
  const hash = await sha256Hex(token);
  if (!/^[0-9a-f]{64}$/.test(hash) || hash.includes(token)) {
    throw new Error("invalid status token hash");
  }
});

Deno.test("anonymous begin request carries only the request ID", () => {
  if (!isAnonymousBeginRequest({ requestId })) {
    throw new Error("valid anonymous begin request rejected");
  }
  if (isAnonymousBeginRequest({ requestId, extra: true })) {
    throw new Error("unknown anonymous begin field accepted");
  }
  if (isAnonymousBeginRequest({ requestId: "not-a-uuid" })) {
    throw new Error("invalid request ID accepted");
  }
  const apple = parseBeginRequest({ requestId, appleAuthorizationCode: "c" });
  const anonymous = parseBeginRequest({ requestId });
  if (
    apple?.appleAuthorizationCode !== "c" ||
    anonymous?.appleAuthorizationCode !== null ||
    anonymous.requestId !== requestId ||
    parseBeginRequest({ requestId, appleAuthorizationCode: "" }) !== null ||
    parseBeginRequest({ action: "status", requestId, statusToken: token }) !==
      null
  ) {
    throw new Error("begin request parsing is invalid");
  }
});

Deno.test("only an Auth-verified anonymous user without identities skips Apple", () => {
  const appleIdentity = { provider: "apple" };
  const cases: [Parameters<typeof isVerifiedAnonymousUser>[0], boolean][] = [
    [{ is_anonymous: true, identities: [] }, true],
    [{ is_anonymous: true }, true],
    [{ is_anonymous: true, identities: [{ provider: "anonymous" }] }, true],
    // Linking Apple converts the account; never skip its token revocation.
    [{ is_anonymous: true, identities: [appleIdentity] }, false],
    [{ is_anonymous: false, identities: [appleIdentity] }, false],
    [{ identities: [] }, false],
    [{}, false],
  ];
  for (const [user, expected] of cases) {
    if (isVerifiedAnonymousUser(user) !== expected) {
      throw new Error(`anonymous detection is wrong for ${JSON.stringify(user)}`);
    }
  }
  // The JWT claim alone is not trusted: only a strict boolean from Auth counts.
  const forged = { is_anonymous: "true" } as unknown as { is_anonymous: boolean };
  if (isVerifiedAnonymousUser(forged)) {
    throw new Error("non-boolean is_anonymous accepted");
  }
});

Deno.test("each account kind has exactly one begin contract", () => {
  const apple = { requestId, appleAuthorizationCode: "one-time-code" };
  const anonymous = { requestId, appleAuthorizationCode: null };
  if (
    beginContractMismatch(apple, false) !== null ||
    beginContractMismatch(anonymous, true) !== null
  ) {
    throw new Error("matching begin contract rejected");
  }
  if (beginContractMismatch(anonymous, false)?.code !== "invalid_request") {
    throw new Error("Apple account allowed to skip Apple re-authentication");
  }
  if (beginContractMismatch(apple, true)?.code !== "apple_account_required") {
    throw new Error("anonymous account accepted an Apple authorization code");
  }
});
