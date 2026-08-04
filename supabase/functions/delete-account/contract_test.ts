import {
  deletionStatusToken,
  isBeginRequest,
  isStatusRequest,
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
