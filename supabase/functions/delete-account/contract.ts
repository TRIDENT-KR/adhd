const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const STATUS_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export function isBeginRequest(
  body: Record<string, unknown>,
): body is { requestId: string; appleAuthorizationCode: string } {
  return exactKeys(body, ["appleAuthorizationCode", "requestId"]) &&
    typeof body.requestId === "string" && UUID_PATTERN.test(body.requestId) &&
    typeof body.appleAuthorizationCode === "string" &&
    body.appleAuthorizationCode.length > 0 &&
    body.appleAuthorizationCode.length <= 4096;
}

/** Anonymous accounts have no Sign in with Apple session, so they send no code. */
export function isAnonymousBeginRequest(
  body: Record<string, unknown>,
): body is { requestId: string } {
  return exactKeys(body, ["requestId"]) &&
    typeof body.requestId === "string" && UUID_PATTERN.test(body.requestId);
}

export type BeginRequest = {
  requestId: string;
  appleAuthorizationCode: string | null;
};

export function parseBeginRequest(
  body: Record<string, unknown>,
): BeginRequest | null {
  if (isBeginRequest(body)) {
    return {
      requestId: body.requestId,
      appleAuthorizationCode: body.appleAuthorizationCode,
    };
  }
  if (isAnonymousBeginRequest(body)) {
    return { requestId: body.requestId, appleAuthorizationCode: null };
  }
  return null;
}

/**
 * True only for an Auth user the server itself returned as anonymous with no
 * linked provider identity. Linking Apple clears `is_anonymous`, which sends
 * the account back to the Apple re-authentication and revocation path.
 */
export function isVerifiedAnonymousUser(user: {
  is_anonymous?: boolean;
  identities?: { provider?: string }[];
}): boolean {
  return user.is_anonymous === true &&
    (user.identities ?? []).every((identity) =>
      identity.provider === "anonymous"
    );
}

/**
 * Each account kind has exactly one begin contract: Apple accounts must send a
 * fresh Apple authorization code, verified anonymous accounts must not.
 */
export function beginContractMismatch(
  begin: BeginRequest,
  anonymousUser: boolean,
): { code: "apple_account_required"; status: 403 } | {
  code: "invalid_request";
  status: 400;
} | null {
  if (anonymousUser) {
    return begin.appleAuthorizationCode === null
      ? null
      : { code: "apple_account_required", status: 403 };
  }
  return begin.appleAuthorizationCode === null
    ? { code: "invalid_request", status: 400 }
    : null;
}

export function isStatusRequest(
  body: Record<string, unknown>,
): body is { action: "status"; requestId: string; statusToken: string } {
  return exactKeys(body, ["action", "requestId", "statusToken"]) &&
    body.action === "status" && typeof body.requestId === "string" &&
    UUID_PATTERN.test(body.requestId) && typeof body.statusToken === "string" &&
    STATUS_TOKEN_PATTERN.test(body.statusToken);
}

export async function deletionStatusToken(
  userId: string,
  requestId: string,
  secret: string,
): Promise<string> {
  if (new TextEncoder().encode(secret).length < 32) {
    throw new Error("deletion_status_secret_too_short");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(
      `${userId.toLowerCase()}:${requestId.toLowerCase()}`,
    ),
  );
  return base64URLEncode(new Uint8Array(signature));
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

function exactKeys(body: Record<string, unknown>, expected: string[]): boolean {
  return JSON.stringify(Object.keys(body).sort()) === JSON.stringify(expected);
}

function base64URLEncode(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll(
    "=",
    "",
  );
}
