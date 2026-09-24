// deno test -A supabase/functions/_shared/apple-jws_test.ts   (테스트 PKI는 WebCrypto로 생성, openssl 불필요)
import "npm:reflect-metadata@0.2.2";
import * as x509 from "npm:@peculiar/x509@2.1.0";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { b64u, der, type Issued, issue, makeRoot, OID_LEAF, OID_WWDR, signJws as signPkiJws } from "./test-pki.ts";
import {
  APPLE_ROOT_CA_G3_DER_B64,
  APPLE_ROOT_CA_G3_SHA256,
  AppleJwsError,
  type AppleJwsErrorCode,
  base64ToBytes,
  sha256Hex,
  verifyAppleChain,
  verifyAppleJws,
  verifyAppleNotification,
} from "./apple-jws.ts";

// ---------- test PKI (root P-384 -> intermediate P-384 -> leaf P-256), all in WebCrypto ----------
const DAY = 86_400_000;
const root = await makeRoot("Test Root CA - G3");
const otherRoot = await makeRoot("Attacker Root");
const int = await issue(root, "Test WWDR G6", { ca: true, oid: OID_WWDR });
const intNoOid = await issue(root, "Test WWDR no OID", { ca: true });
const leaf = await issue(int, "Test Receipt Signing", { ca: false, oid: OID_LEAF });
const leafNoOid = await issue(int, "Leaf no OID", { ca: false });
const leafExpired = await issue(int, "Leaf expired", {
  ca: false, oid: OID_LEAF, notBefore: new Date("2020-01-01"), notAfter: new Date("2021-01-01"),
});
const leafUnderNoOidInt = await issue(intNoOid, "Leaf under bad int", { ca: false, oid: OID_LEAF });
// Attacker builds an identical-looking chain under their own root.
const evilInt = await issue(otherRoot, "Test WWDR G6", { ca: true, oid: OID_WWDR });
const evilLeaf = await issue(evilInt, "Test Receipt Signing", { ca: false, oid: OID_LEAF });

type Leaf = Issued;
async function signJws(
  payload: unknown,
  o: { leaf?: Leaf; chain?: x509.X509Certificate[]; alg?: string } = {},
) {
  const l = o.leaf ?? leaf;
  return await signPkiJws(payload, { leaf: l, intermediate: int, root }, {
    alg: o.alg,
    x5c: o.chain ?? [l.cert, int.cert, root.cert],
  });
}

const tx = (over: Record<string, unknown> = {}) => ({
  transactionId: "2000000123456789", originalTransactionId: "2000000123456789",
  bundleId: "com.test.app", productId: "pro.monthly", environment: "Sandbox",
  purchaseDate: Date.now() - 1000, signedDate: Date.now(), ...over,
});
const opts = { pinnedRootsDer: [der(root.cert)], expectedBundleId: "com.test.app", expectedEnvironment: "Sandbox" };

async function rejectsWith(p: Promise<unknown>, code: AppleJwsErrorCode) {
  const e = await assertRejects(() => p, AppleJwsError);
  assertEquals(e.code, code, e.message);
}

// ---------- tests ----------
Deno.test("accepts a valid chain when the test root is pinned", async () => {
  const out = await verifyAppleJws<{ productId: string }>(await signJws(tx()), opts);
  assertEquals(out.productId, "pro.monthly");
});

Deno.test("rejects when a different root is pinned", async () => {
  await rejectsWith(verifyAppleJws(await signJws(tx()), { ...opts, pinnedRootsDer: [der(otherRoot.cert)] }), "UNTRUSTED_CHAIN");
});

Deno.test("never trusts x5c[2]: attacker chain with attacker root in x5c", async () => {
  const jws = await signJws(tx(), { leaf: evilLeaf, chain: [evilLeaf.cert, evilInt.cert, otherRoot.cert] });
  await rejectsWith(verifyAppleJws(jws, opts), "UNTRUSTED_CHAIN");
  // also with the pinned root's bytes placed in x5c[2]
  const jws2 = await signJws(tx(), { leaf: evilLeaf, chain: [evilLeaf.cert, evilInt.cert, root.cert] });
  await rejectsWith(verifyAppleJws(jws2, opts), "UNTRUSTED_CHAIN");
});

Deno.test("rejects tampered payload", async () => {
  const [h, , s] = (await signJws(tx())).split(".");
  const forged = `${h}.${b64u(JSON.stringify(tx({ productId: "pro.lifetime" })))}.${s}`;
  await rejectsWith(verifyAppleJws(forged, opts), "INVALID_SIGNATURE");
});

Deno.test("rejects leaf without 1.2.840.113635.100.6.11.1", async () => {
  await rejectsWith(verifyAppleJws(await signJws(tx(), { leaf: leafNoOid }), opts), "MISSING_APPLE_OID");
});

Deno.test("rejects intermediate without 1.2.840.113635.100.6.2.1", async () => {
  const jws = await signJws(tx(), { leaf: leafUnderNoOidInt, chain: [leafUnderNoOidInt.cert, intNoOid.cert, root.cert] });
  await rejectsWith(verifyAppleJws(jws, opts), "MISSING_APPLE_OID");
});

Deno.test("rejects expired leaf", async () => {
  await rejectsWith(verifyAppleJws(await signJws(tx(), { leaf: leafExpired }), opts), "CERT_NOT_VALID_AT_TIME");
});

Deno.test("rejects when `now` is past the leaf's notAfter", async () => {
  await rejectsWith(
    verifyAppleJws(await signJws(tx()), { ...opts, now: new Date(Date.now() + 400 * DAY) }),
    "CERT_NOT_VALID_AT_TIME",
  );
});

Deno.test("rejects alg != ES256", async () => {
  for (const alg of ["ES384", "ES512", "HS256", "none", "RS256"]) {
    await rejectsWith(verifyAppleJws(await signJws(tx(), { alg }), opts), "UNSUPPORTED_ALG");
  }
});

Deno.test("rejects wrong bundleId / environment", async () => {
  await rejectsWith(verifyAppleJws(await signJws(tx({ bundleId: "com.evil" })), opts), "BUNDLE_ID_MISMATCH");
  await rejectsWith(verifyAppleJws(await signJws(tx({ environment: "Production" })), opts), "ENVIRONMENT_MISMATCH");
});

Deno.test("rejects malformed input and bad chain length", async () => {
  await rejectsWith(verifyAppleJws("a.b", opts), "MALFORMED_JWS");
  await rejectsWith(verifyAppleJws("!!.@@.##", opts), "MALFORMED_JWS");
  const two = await signJws(tx(), { chain: [leaf.cert, int.cert] });
  await rejectsWith(verifyAppleJws(two, opts), "INVALID_CHAIN_LENGTH");
  await rejectsWith(verifyAppleJws(await signJws(tx()), { ...opts, pinnedRootsDer: [] }), "NO_PINNED_ROOTS");
});

Deno.test("notification V2: verifies outer and nested JWS", async () => {
  const signedTransactionInfo = await signJws(tx());
  const signedRenewalInfo = await signJws({ autoRenewStatus: 1, environment: "Sandbox", signedDate: Date.now() });
  const signedPayload = await signJws({
    notificationType: "DID_RENEW", notificationUUID: crypto.randomUUID(), signedDate: Date.now(), version: "2.0",
    data: { bundleId: "com.test.app", environment: "Sandbox", signedTransactionInfo, signedRenewalInfo },
  });
  const r = await verifyAppleNotification(signedPayload, opts);
  assertEquals(r.notification.notificationType, "DID_RENEW");
  assertEquals(r.transaction?.productId, "pro.monthly");
  assertEquals(r.renewalInfo?.autoRenewStatus, 1);

  // nested JWS tampered -> whole notification rejected
  const [h, , s] = signedTransactionInfo.split(".");
  const badNested = await signJws({
    notificationType: "DID_RENEW", signedDate: Date.now(),
    data: { bundleId: "com.test.app", environment: "Sandbox", signedTransactionInfo: `${h}.${b64u(JSON.stringify(tx({ productId: "x" })))}.${s}` },
  });
  await rejectsWith(verifyAppleNotification(badNested, opts), "INVALID_SIGNATURE");
});

Deno.test("pinned Apple Root CA - G3 constant matches its fingerprint", async () => {
  assertEquals(await sha256Hex(base64ToBytes(APPLE_ROOT_CA_G3_DER_B64)), APPLE_ROOT_CA_G3_SHA256);
});

// Real Apple certs (MIT-licensed test vectors from @apple/app-store-server-library): leaf valid 2025-09-19..2027-10-13.
const REAL_WWDR_G6 =
  "MIIDFjCCApygAwIBAgIUIsGhRwp0c2nvU4YSycafPTjzbNcwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMjEwMzE3MjAzNzEwWhcNMzYwMzE5MDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbsQKC94PrlWmZXnXgtxzdVJL8T0SGYngDRGpngn3N6PT8JMEb7FDi4bBmPhCnZ3/sq6PF/cGcKXWsL5vOteRhyJ45x3ASP7cOB+aao90fcpxSv/EZFbniAbNgZGhIhpIo4H6MIH3MBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUu7DeoVgziJqkipnevr3rr9rLJKswRgYIKwYBBQUHAQEEOjA4MDYGCCsGAQUFBzABhipodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNhZzMwNwYDVR0fBDAwLjAsoCqgKIYmaHR0cDovL2NybC5hcHBsZS5jb20vYXBwbGVyb290Y2FnMy5jcmwwHQYDVR0OBBYEFD8vlCNR01DJmig97bB85c+lkGKZMA4GA1UdDwEB/wQEAwIBBjAQBgoqhkiG92NkBgIBBAIFADAKBggqhkjOPQQDAwNoADBlAjBAXhSq5IyKogMCPtw490BaB677CaEGJXufQB/EqZGd6CSjiCtOnuMTbXVXmxxcxfkCMQDTSPxarZXvNrkxU3TkUMI33yzvFVVRT4wxWJC994OsdcZ4+RGNsYDyR5gmdr0nDGg=";
const REAL_LEAF =
  "MIIEMTCCA7agAwIBAgIQR8KHzdn554Z/UoradNx9tzAKBggqhkjOPQQDAzB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJBgNVBAYTAlVTMB4XDTI1MDkxOTE5NDQ1MVoXDTI3MTAxMzE3NDcyM1owgZIxQDA+BgNVBAMMN1Byb2QgRUNDIE1hYyBBcHAgU3RvcmUgYW5kIGlUdW5lcyBTdG9yZSBSZWNlaXB0IFNpZ25pbmcxLDAqBgNVBAsMI0FwcGxlIFdvcmxkd2lkZSBEZXZlbG9wZXIgUmVsYXRpb25zMRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABNnVvhcv7iT+7Ex5tBMBgrQspHzIsXRi0Yxfek7lv8wEmj/bHiWtNwJqc2BoHzsQiEjP7KFIIKg4Y8y0/nynuAmjggIIMIICBDAMBgNVHRMBAf8EAjAAMB8GA1UdIwQYMBaAFD8vlCNR01DJmig97bB85c+lkGKZMHAGCCsGAQUFBwEBBGQwYjAtBggrBgEFBQcwAoYhaHR0cDovL2NlcnRzLmFwcGxlLmNvbS93d2RyZzYuZGVyMDEGCCsGAQUFBzABhiVodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLXd3ZHJnNjAyMIIBHgYDVR0gBIIBFTCCAREwggENBgoqhkiG92NkBQYBMIH+MIHDBggrBgEFBQcCAjCBtgyBs1JlbGlhbmNlIG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBjb25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZpY2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMDYGCCsGAQUFBwIBFipodHRwOi8vd3d3LmFwcGxlLmNvbS9jZXJ0aWZpY2F0ZWF1dGhvcml0eS8wHQYDVR0OBBYEFIFioG4wMMVA1ku9zJmGNPAVn3eqMA4GA1UdDwEB/wQEAwIHgDAQBgoqhkiG92NkBgsBBAIFADAKBggqhkjOPQQDAwNpADBmAjEA+qXnREC7hXIWVLsLxznjRpIzPf7VHz9V/CTm8+LJlrQepnmcPvGLNcX6XPnlcgLAAjEA5IjNZKgg5pQ79knF4IbTXdKv8vutIDMXDmjPVT3dGvFtsGRwXOywR2kZCdSrfeot";

Deno.test("real Apple chain (Prod leaf -> WWDR G6 -> pinned G3) passes; fails with a test root pinned", async () => {
  const x5c = [REAL_LEAF, REAL_WWDR_G6, APPLE_ROOT_CA_G3_DER_B64];
  const pinned = { pinnedRootsDer: [base64ToBytes(APPLE_ROOT_CA_G3_DER_B64)], now: new Date("2026-06-01T00:00:00Z") };
  const key = await verifyAppleChain(x5c, pinned);
  assertEquals((key.algorithm as EcKeyAlgorithm).namedCurve, "P-256");
  await rejectsWith(verifyAppleChain(x5c, { ...pinned, pinnedRootsDer: [der(root.cert)] }), "UNTRUSTED_CHAIN");
  await rejectsWith(verifyAppleChain(x5c, { ...pinned, now: new Date("2028-01-01T00:00:00Z") }), "CERT_NOT_VALID_AT_TIME");
  assert(true);
});
