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
