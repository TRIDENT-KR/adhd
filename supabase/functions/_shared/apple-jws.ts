// Verify Apple App Store signed data (StoreKit 2 JWS, App Store Server Notifications V2).
// Portable: X.509 parsing via @peculiar/x509, every signature check via WebCrypto.
// Works in Deno CLI 2.x and Supabase edge-runtime (Deno 2.1.4 compat), where
// node:crypto X509Certificate.verify/checkIssued/raw are NOT implemented.
import "npm:reflect-metadata@0.2.2"; // must be evaluated before @peculiar/x509 (tsyringe needs it)
import * as x509 from "npm:@peculiar/x509@2.1.0";

x509.cryptoProvider.set(globalThis.crypto);

/** Apple Root CA - G3, DER, base64. https://www.apple.com/certificateauthority/AppleRootCA-G3.cer */
export const APPLE_ROOT_CA_G3_DER_B64 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";
/** SHA-256 of the DER above (lowercase hex). */
export const APPLE_ROOT_CA_G3_SHA256 =
  "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";

const OID_APPLE_LEAF = "1.2.840.113635.100.6.11.1"; // Mac App Store / iTunes Store receipt signing
const OID_APPLE_WWDR = "1.2.840.113635.100.6.2.1"; // Apple WWDR intermediate marker
const MAX_SKEW_MS = 60_000; // same tolerance as Apple's SignedDataVerifier

export type AppleJwsErrorCode =
  | "NO_PINNED_ROOTS"
  | "MALFORMED_JWS"
  | "UNSUPPORTED_ALG"
  | "INVALID_CHAIN_LENGTH"
  | "INVALID_CERTIFICATE"
  | "UNTRUSTED_CHAIN"
  | "MISSING_APPLE_OID"
  | "CERT_NOT_VALID_AT_TIME"
  | "INVALID_SIGNATURE"
  | "BUNDLE_ID_MISMATCH"
  | "ENVIRONMENT_MISMATCH";

export class AppleJwsError extends Error {
  override name = "AppleJwsError";
  constructor(readonly code: AppleJwsErrorCode, message: string, options?: ErrorOptions) {
    super(`${code}: ${message}`, options);
  }
}

export interface VerifyAppleJwsOptions {
  /** DER bytes of trusted roots. Production: [base64ToBytes(APPLE_ROOT_CA_G3_DER_B64)]. */
  pinnedRootsDer: Uint8Array[];
  /** Reference time for certificate validity. Default: current time. */
  now?: Date;
  /** Checked against payload.bundleId (or data/summary/appData.bundleId for notifications). */
  expectedBundleId?: string;
  /** "Production" | "Sandbox"; checked like the bundle id. */
  expectedEnvironment?: string;
}

// ---------- encoding helpers ----------
const B64URL = /^[A-Za-z0-9_-]+$/;
const B64 = /^[A-Za-z0-9+/]+={0,2}$/;

export function base64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  if (!B64.test(b64)) throw new Error("invalid base64");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function base64UrlToBytes(s: string): Uint8Array<ArrayBuffer> {
  if (!B64URL.test(s)) throw new Error("invalid base64url");
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  return base64ToBytes(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
}

function decodeJsonPart(part: string, what: string): Record<string, unknown> {
  let v: unknown;
  try {
    v = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(base64UrlToBytes(part)));
  } catch (e) {
    throw new AppleJwsError("MALFORMED_JWS", `${what} is not base64url JSON`, { cause: e });
  }
  if (typeof v !== "object" || v === null || Array.isArray(v)) {
    throw new AppleJwsError("MALFORMED_JWS", `${what} is not a JSON object`);
  }
  return v as Record<string, unknown>;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes.slice()));
  return Array.from(d, (b) => b.toString(16).padStart(2, "0")).join("");
}

// ---------- certificate chain ----------
function parseCert(der: Uint8Array, what: string): x509.X509Certificate {
  try {
    return new x509.X509Certificate(der.slice()); // slice(): own ArrayBuffer copy
  } catch (e) {
    throw new AppleJwsError("INVALID_CERTIFICATE", `${what} is not a valid X.509 certificate`, { cause: e });
  }
}

async function signedBy(child: x509.X509Certificate, issuer: x509.X509Certificate): Promise<boolean> {
  if (child.issuer !== issuer.subject) return false;
  try {
    // signatureOnly: dates are checked separately with our own clock/skew.
    return await child.verify({ publicKey: issuer, signatureOnly: true });
  } catch {
    return false;
  }
}

function assertValidAt(cert: x509.X509Certificate, now: Date, what: string) {
  const t = now.getTime();
  if (cert.notBefore.getTime() > t + MAX_SKEW_MS || cert.notAfter.getTime() < t - MAX_SKEW_MS) {
    throw new AppleJwsError(
      "CERT_NOT_VALID_AT_TIME",
      `${what} valid ${cert.notBefore.toISOString()}..${cert.notAfter.toISOString()}, checked at ${now.toISOString()}`,
    );
  }
}

/**
 * Verifies x5c[0] (leaf) -> x5c[1] (intermediate) -> one of the pinned roots.
 * x5c[2] is never trusted. Returns the leaf's P-256 public key as a WebCrypto key.
 */
export async function verifyAppleChain(
  x5c: unknown,
  opts: Pick<VerifyAppleJwsOptions, "pinnedRootsDer" | "now">,
): Promise<CryptoKey> {
  if (!opts.pinnedRootsDer?.length) throw new AppleJwsError("NO_PINNED_ROOTS", "pinnedRootsDer is empty");
  if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every((c) => typeof c === "string")) {
    throw new AppleJwsError("INVALID_CHAIN_LENGTH", "x5c must be an array of exactly 3 base64 certificates");
  }
  const now = opts.now ?? new Date();
  let leafDer: Uint8Array, intDer: Uint8Array;
  try {
    leafDer = base64ToBytes(x5c[0]);
    intDer = base64ToBytes(x5c[1]);
  } catch (e) {
    throw new AppleJwsError("INVALID_CERTIFICATE", "x5c entry is not base64", { cause: e });
  }
  const leaf = parseCert(leafDer, "leaf");
  const intermediate = parseCert(intDer, "intermediate");
  const roots = opts.pinnedRootsDer.map((d, i) => parseCert(d, `pinned root #${i}`));

  let root: x509.X509Certificate | undefined;
  for (const r of roots) {
    if (await signedBy(intermediate, r)) {
      root = r;
      break;
    }
  }
  if (!root) throw new AppleJwsError("UNTRUSTED_CHAIN", "intermediate is not signed by any pinned root");
  if (!(await signedBy(leaf, intermediate))) {
    throw new AppleJwsError("UNTRUSTED_CHAIN", "leaf is not signed by the intermediate");
  }
  const bc = intermediate.getExtension(x509.BasicConstraintsExtension);
  if (!bc?.ca) throw new AppleJwsError("UNTRUSTED_CHAIN", "intermediate is not a CA");
  if (!leaf.getExtension(OID_APPLE_LEAF)) {
    throw new AppleJwsError("MISSING_APPLE_OID", `leaf lacks ${OID_APPLE_LEAF}`);
  }
  if (!intermediate.getExtension(OID_APPLE_WWDR)) {
    throw new AppleJwsError("MISSING_APPLE_OID", `intermediate lacks ${OID_APPLE_WWDR}`);
  }
  assertValidAt(leaf, now, "leaf");
  assertValidAt(intermediate, now, "intermediate");
  assertValidAt(root, now, "root");

  try {
    // Throws unless the SPKI really is an EC P-256 key (required for ES256).
    return await crypto.subtle.importKey(
      "spki",
      leaf.publicKey.rawData,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
  } catch (e) {
    throw new AppleJwsError("INVALID_CERTIFICATE", "leaf key is not EC P-256", { cause: e });
  }
}

// ---------- JWS ----------
type Scoped = { bundleId?: unknown; environment?: unknown };

function scopeOf(payload: Record<string, unknown>): Scoped {
  // Notifications carry bundleId/environment under data | summary | appData; transactions at top level.
  for (const k of ["data", "summary", "appData"]) {
    const v = payload[k];
    if (v && typeof v === "object") return v as Scoped;
  }
  return payload as Scoped;
}

/** Verifies an Apple-signed ES256 x5c JWS and returns its decoded payload. Throws AppleJwsError. */
export async function verifyAppleJws<T = Record<string, unknown>>(
  jws: string,
  opts: VerifyAppleJwsOptions,
): Promise<T> {
  if (typeof jws !== "string") throw new AppleJwsError("MALFORMED_JWS", "JWS must be a string");
  const parts = jws.split(".");
  if (parts.length !== 3 || parts.some((p) => p.length === 0)) {
    throw new AppleJwsError("MALFORMED_JWS", "expected 3 non-empty compact-serialization segments");
  }
  const [h, p, s] = parts;
  const header = decodeJsonPart(h, "header");
  if (header.alg !== "ES256") {
    throw new AppleJwsError("UNSUPPORTED_ALG", `alg must be ES256, got ${JSON.stringify(header.alg)}`);
  }
  if ("crit" in header) throw new AppleJwsError("MALFORMED_JWS", "crit header is not supported");

  const leafKey = await verifyAppleChain(header.x5c, opts);

  let sig: Uint8Array<ArrayBuffer>;
  try {
    sig = base64UrlToBytes(s);
  } catch (e) {
    throw new AppleJwsError("MALFORMED_JWS", "signature is not base64url", { cause: e });
  }
  if (sig.length !== 64) throw new AppleJwsError("INVALID_SIGNATURE", "ES256 signature must be 64 bytes (r||s)");
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    leafKey,
    sig,
    new TextEncoder().encode(`${h}.${p}`),
  );
  if (!ok) throw new AppleJwsError("INVALID_SIGNATURE", "JWS signature does not verify with the leaf key");

  const payload = decodeJsonPart(p, "payload");
  const scope = scopeOf(payload);
  if (opts.expectedBundleId !== undefined && scope.bundleId !== opts.expectedBundleId) {
    throw new AppleJwsError("BUNDLE_ID_MISMATCH", `bundleId ${JSON.stringify(scope.bundleId)}`);
  }
  if (opts.expectedEnvironment !== undefined && scope.environment !== opts.expectedEnvironment) {
    throw new AppleJwsError("ENVIRONMENT_MISMATCH", `environment ${JSON.stringify(scope.environment)}`);
  }
  return payload as T;
}

/**
 * App Store Server Notifications V2: verifies signedPayload and the nested
 * data.signedTransactionInfo / data.signedRenewalInfo JWS (each independently).
 * signedRenewalInfo has no bundleId, so only the environment is checked there.
 */
export async function verifyAppleNotification(signedPayload: string, opts: VerifyAppleJwsOptions) {
  const notification = await verifyAppleJws<Record<string, unknown>>(signedPayload, opts);
  const data = (notification.data ?? {}) as Record<string, unknown>;
  const transaction = typeof data.signedTransactionInfo === "string"
    ? await verifyAppleJws<Record<string, unknown>>(data.signedTransactionInfo, opts)
    : undefined;
  const renewalInfo = typeof data.signedRenewalInfo === "string"
    ? await verifyAppleJws<Record<string, unknown>>(data.signedRenewalInfo, { ...opts, expectedBundleId: undefined })
    : undefined;
  return { notification, transaction, renewalInfo };
}
