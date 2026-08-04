import {
  createClient,
  type SupabaseClient,
  type User,
} from "@supabase/supabase-js";
import {
  deletionStatusToken,
  isBeginRequest,
  isStatusRequest,
  sha256Hex,
} from "./contract.ts";

type DeletionStatus =
  | "requested"
  | "running"
  | "retry_wait"
  | "completed"
  | "failed";

type DeletionJob = {
  jobId: string;
  requestId: string;
  status: DeletionStatus;
  userId: string | null;
  appleRevokedAt: string | null;
  dataPurgedAt: string | null;
  authDeletedAt: string | null;
  nextAttemptAt: string | null;
  requiresAppleReauth: boolean;
  claimed?: boolean;
  reason?: string | null;
};

type AppleTokenResponse = {
  access_token: string;
  refresh_token?: string;
  id_token: string;
};

type AppleJWK = JsonWebKey & { kid?: string };

class DeletionFailure extends Error {
  constructor(
    readonly code: string,
    readonly status: number,
    readonly retryable = false,
    readonly requiresAppleReauth = false,
  ) {
    super(code);
  }
}

const JSON_HEADERS = {
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
};

let appleKeyCache: { expiresAt: number; keys: AppleJWK[] } | undefined;

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return jsonError(405, "method_not_allowed", null, undefined, {
      Allow: "POST",
    });
  }

  let requestId: string | null = null;
  try {
    const body = await readStrictJSON(request);
    requestId = typeof body.requestId === "string" ? body.requestId : null;
    const service = serviceClient();

    if (isStatusRequest(body)) {
      const tokenHash = await sha256Hex(body.statusToken);
      const current = await rpc<DeletionJob | null>(
        service,
        "mora_get_account_deletion_status",
        {
          p_request_id: body.requestId,
          p_status_token_hash: tokenHash,
        },
      );
      if (!current) return jsonError(404, "deletion_not_found", body.requestId);
      if (current.status === "completed") return jobResponse(current, 200);

      const advanced = await advanceDeletion(
        service,
        body.requestId,
        tokenHash,
        undefined,
      );
      return responseForJob(advanced);
    }

    if (!isBeginRequest(body)) {
      return jsonError(400, "invalid_request", requestId);
    }

    const authenticated = await authenticateRecentAppleSession(
      request,
      service,
    );
    const statusToken = await deletionStatusToken(
      authenticated.user.id,
      body.requestId,
      requiredEnv("DELETION_STATUS_SECRET"),
    );
    const tokenHash = await sha256Hex(statusToken);
    const begun = await rpc<DeletionJob>(
      service,
      "mora_begin_account_deletion",
      {
        p_user_id: authenticated.user.id,
        p_request_id: body.requestId,
        p_status_token_hash: tokenHash,
      },
    );
    if (!begun) throw new DeletionFailure("deletion_begin_failed", 503, true);

    try {
      const advanced = await advanceDeletion(
        service,
        body.requestId,
        tokenHash,
        {
          authorizationCode: body.appleAuthorizationCode,
          expectedAppleSubject: authenticated.appleSubject,
        },
      );
      return responseForJob(advanced, statusToken);
    } catch (error) {
      if (error instanceof DeletionFailure && error.requiresAppleReauth) {
        const retryJob = await markRetry(
          service,
          body.requestId,
          tokenHash,
          error.code,
          true,
        );
        return jsonError(
          409,
          "apple_reauth_required",
          body.requestId,
          retryJob,
          undefined,
          statusToken,
        );
      }
      throw error;
    }
  } catch (error) {
    if (error instanceof DeletionFailure) {
      return jsonError(error.status, error.code, requestId);
    }
    console.error("account_deletion_unexpected_failure", { requestId });
    return jsonError(503, "deletion_service_unavailable", requestId);
  }
});

async function advanceDeletion(
  service: SupabaseClient,
  requestId: string,
  tokenHash: string,
  apple:
    | { authorizationCode: string; expectedAppleSubject: string }
    | undefined,
): Promise<DeletionJob> {
  let job = await rpc<DeletionJob | null>(
    service,
    "mora_claim_account_deletion",
    {
      p_request_id: requestId,
      p_status_token_hash: tokenHash,
    },
  );
  if (!job) throw new DeletionFailure("deletion_not_found", 404);
  if (job.status === "completed" || job.claimed === false) return job;
  if (!job.userId) {
    throw new DeletionFailure("deletion_state_invalid", 503, true);
  }

  try {
    if (!job.appleRevokedAt) {
      if (!apple) {
        await markRetry(
          service,
          requestId,
          tokenHash,
          "apple_reauth_required",
          true,
        );
        throw new DeletionFailure("apple_reauth_required", 409, false, true);
      }
      await exchangeValidateAndRevokeAppleTokens(
        apple.authorizationCode,
        apple.expectedAppleSubject,
      );
      job = await rpc<DeletionJob>(
        service,
        "mora_mark_account_deletion_apple_revoked",
        {
          p_request_id: requestId,
          p_status_token_hash: tokenHash,
        },
      );
    }

    if (!job.dataPurgedAt) {
      job = await rpc<DeletionJob>(
        service,
        "mora_purge_account_deletion_data",
        {
          p_request_id: requestId,
          p_status_token_hash: tokenHash,
        },
      );
    }

    const userId = job.userId;
    if (!userId) throw new DeletionFailure("deletion_state_invalid", 503, true);
    const { error: deleteError } = await service.auth.admin.deleteUser(userId);
    if (deleteError && !isAlreadyDeleted(deleteError)) {
      throw new DeletionFailure("auth_delete_failed", 503, true);
    }

    job = await rpc<DeletionJob>(service, "mora_complete_account_deletion", {
      p_request_id: requestId,
      p_status_token_hash: tokenHash,
    });
    console.info("account_deletion_completed", { requestId });
    return job;
  } catch (error) {
    if (error instanceof DeletionFailure && error.requiresAppleReauth) {
      throw error;
    }
    const code = error instanceof DeletionFailure
      ? error.code
      : "deletion_step_failed";
    return await markRetry(service, requestId, tokenHash, code, false);
  }
}

async function markRetry(
  service: SupabaseClient,
  requestId: string,
  tokenHash: string,
  code: string,
  requiresAppleReauth: boolean,
): Promise<DeletionJob> {
  return await rpc<DeletionJob>(service, "mora_mark_account_deletion_retry", {
    p_request_id: requestId,
    p_status_token_hash: tokenHash,
    p_failure_code: code,
    p_requires_apple_reauth: requiresAppleReauth,
  });
}

async function authenticateRecentAppleSession(
  request: Request,
  service: SupabaseClient,
): Promise<{ user: User; appleSubject: string }> {
  const authorization = request.headers.get("Authorization") ?? "";
  const match = authorization.match(/^Bearer ([^\s]+)$/);
  if (!match) throw new DeletionFailure("authentication_required", 401);

  const jwt = match[1];
  const { data, error } = await service.auth.getUser(jwt);
  if (error || !data.user) throw new DeletionFailure("invalid_session", 401);

  const claims = decodeJWTPayload(jwt);
  const now = Math.floor(Date.now() / 1000);
  if (
    typeof claims.iat !== "number" || claims.iat > now + 60 ||
    now - claims.iat > 300
  ) {
    throw new DeletionFailure("recent_authentication_required", 401);
  }

  const appleIdentity = data.user.identities?.find((identity) =>
    identity.provider === "apple"
  );
  const identityData = appleIdentity?.identity_data as
    | Record<string, unknown>
    | undefined;
  const appleSubject = identityData?.sub ?? appleIdentity?.identity_id;
  const providers = data.user.app_metadata?.providers;
  if (
    data.user.app_metadata?.provider !== "apple" ||
    !Array.isArray(providers) ||
    providers.some((provider) => provider !== "apple") ||
    typeof appleSubject !== "string" ||
    appleSubject.length === 0
  ) {
    throw new DeletionFailure("apple_account_required", 403);
  }
  return { user: data.user, appleSubject };
}

async function exchangeValidateAndRevokeAppleTokens(
  authorizationCode: string,
  expectedAppleSubject: string,
): Promise<void> {
  const clientId = requiredEnv("APPLE_CLIENT_ID");
  const clientSecret = requiredEnv("APPLE_CLIENT_SECRET");
  const tokenResponse = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      code: authorizationCode,
      grant_type: "authorization_code",
    }),
  });
  if (!tokenResponse.ok) {
    throw new DeletionFailure("apple_token_exchange_failed", 409, false, true);
  }

  const tokens = await tokenResponse.json() as Partial<AppleTokenResponse>;
  if (!tokens.access_token || !tokens.id_token) {
    throw new DeletionFailure("apple_token_response_invalid", 409, false, true);
  }
  const subject = await verifyAppleIdentityToken(tokens.id_token, clientId);
  if (subject !== expectedAppleSubject) {
    throw new DeletionFailure("apple_identity_mismatch", 409, false, true);
  }

  await revokeAppleToken(
    tokens.access_token,
    "access_token",
    clientId,
    clientSecret,
  );
  if (tokens.refresh_token) {
    await revokeAppleToken(
      tokens.refresh_token,
      "refresh_token",
      clientId,
      clientSecret,
    );
  }
}

async function revokeAppleToken(
  token: string,
  hint: "access_token" | "refresh_token",
  clientId: string,
  clientSecret: string,
): Promise<void> {
  const response = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      token,
      token_type_hint: hint,
    }),
  });
  if (!response.ok) {
    throw new DeletionFailure(
      "apple_token_revocation_failed",
      409,
      false,
      true,
    );
  }
}

async function verifyAppleIdentityToken(
  token: string,
  clientId: string,
): Promise<string> {
  const parts = token.split(".");
  if (parts.length !== 3) {
    throw new DeletionFailure("apple_identity_token_invalid", 409, false, true);
  }
  const header = JSON.parse(
    new TextDecoder().decode(base64URLDecode(parts[0])),
  ) as {
    alg?: string;
    kid?: string;
  };
  const payload = JSON.parse(
    new TextDecoder().decode(base64URLDecode(parts[1])),
  ) as {
    iss?: string;
    aud?: string | string[];
    exp?: number;
    sub?: string;
  };
  if (header.alg !== "RS256" || !header.kid) {
    throw new DeletionFailure("apple_identity_token_invalid", 409, false, true);
  }

  const jwk = (await appleKeys()).find((key) => key.kid === header.kid);
  if (!jwk) {
    throw new DeletionFailure(
      "apple_signing_key_unavailable",
      409,
      false,
      true,
    );
  }
  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const validSignature = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    base64URLDecode(parts[2]).buffer as ArrayBuffer,
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
  );
  const validAudience = payload.aud === clientId ||
    (Array.isArray(payload.aud) && payload.aud.includes(clientId));
  if (
    !validSignature || payload.iss !== "https://appleid.apple.com" ||
    !validAudience || typeof payload.exp !== "number" ||
    payload.exp <= Date.now() / 1000 ||
    typeof payload.sub !== "string" || payload.sub.length === 0
  ) {
    throw new DeletionFailure("apple_identity_token_invalid", 409, false, true);
  }
  return payload.sub;
}

async function appleKeys(): Promise<AppleJWK[]> {
  if (appleKeyCache && appleKeyCache.expiresAt > Date.now()) {
    return appleKeyCache.keys;
  }
  const response = await fetch("https://appleid.apple.com/auth/keys");
  if (!response.ok) {
    throw new DeletionFailure(
      "apple_signing_key_unavailable",
      409,
      false,
      true,
    );
  }
  const body = await response.json() as { keys?: AppleJWK[] };
  if (!Array.isArray(body.keys) || body.keys.length === 0) {
    throw new DeletionFailure(
      "apple_signing_key_unavailable",
      409,
      false,
      true,
    );
  }
  appleKeyCache = { keys: body.keys, expiresAt: Date.now() + 60 * 60 * 1000 };
  return body.keys;
}

function serviceClient(): SupabaseClient {
  return createClient(
    requiredEnv("SUPABASE_URL"),
    requiredEnv("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: { autoRefreshToken: false, persistSession: false },
    },
  );
}

async function rpc<T>(
  client: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await client.rpc(name, args);
  if (error) {
    console.error("account_deletion_database_failure", { code: name });
    throw new DeletionFailure("deletion_database_unavailable", 503, true);
  }
  return data as T;
}

function isAlreadyDeleted(error: unknown): boolean {
  const value = error as { status?: number; code?: string };
  return value.status === 404 || value.code === "user_not_found";
}

async function readStrictJSON(
  request: Request,
): Promise<Record<string, unknown>> {
  if (
    !(request.headers.get("Content-Type") ?? "").toLowerCase().startsWith(
      "application/json",
    )
  ) {
    throw new DeletionFailure("content_type_required", 400);
  }
  const length = Number(request.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(length) && length > 4096) {
    throw new DeletionFailure("request_too_large", 400);
  }
  let parsed: unknown;
  try {
    const raw = await request.text();
    if (raw.length > 4096) throw new DeletionFailure("request_too_large", 400);
    parsed = JSON.parse(raw);
  } catch (error) {
    if (error instanceof DeletionFailure) throw error;
    throw new DeletionFailure("invalid_json", 400);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new DeletionFailure("invalid_request", 400);
  }
  return parsed as Record<string, unknown>;
}

function decodeJWTPayload(token: string): Record<string, unknown> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new DeletionFailure("invalid_session", 401);
  try {
    return JSON.parse(
      new TextDecoder().decode(base64URLDecode(parts[1])),
    ) as Record<string, unknown>;
  } catch {
    throw new DeletionFailure("invalid_session", 401);
  }
}

function base64URLDecode(value: string): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new DeletionFailure("deletion_service_misconfigured", 503);
  return value;
}

function publicStatus(
  status: DeletionStatus,
): "running" | "retry_wait" | "completed" {
  if (status === "completed") return "completed";
  if (status === "retry_wait") return "retry_wait";
  return "running";
}

function responseForJob(job: DeletionJob, statusToken?: string): Response {
  if (job.requiresAppleReauth) {
    return jsonError(
      409,
      "apple_reauth_required",
      job.requestId,
      job,
      undefined,
      statusToken,
    );
  }
  return jobResponse(job, job.status === "completed" ? 200 : 202, statusToken);
}

function jobResponse(
  job: DeletionJob,
  status: number,
  statusToken?: string,
): Response {
  const body: Record<string, unknown> = {
    requestId: job.requestId,
    jobId: job.jobId,
    status: publicStatus(job.status),
  };
  if (statusToken) body.statusToken = statusToken;
  const headers = status === 202
    ? { ...JSON_HEADERS, "Retry-After": "5" }
    : JSON_HEADERS;
  return new Response(JSON.stringify(body), { status, headers });
}

function jsonError(
  status: number,
  code: string,
  requestId: string | null,
  job?: DeletionJob,
  extraHeaders?: Record<string, string>,
  statusToken?: string,
): Response {
  const body: Record<string, unknown> = {
    error: { code },
    requestId,
  };
  if (job) {
    body.jobId = job.jobId;
    body.status = publicStatus(job.status);
  }
  if (statusToken) body.statusToken = statusToken;
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...JSON_HEADERS, ...extraHeaders },
  });
}
