import { assertEquals } from "jsr:@std/assert@1";

type Handler = (request: Request) => Promise<Response>;
const b64 = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_")
    .replaceAll("=", "");
const encoded = (value: unknown) =>
  b64(new TextEncoder().encode(JSON.stringify(value)));

Deno.test("deletion requires verified Apple proof before locking, but locks before revoking", async (t) => {
  const originalFetch = globalThis.fetch;
  const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  const env = Object.getOwnPropertyDescriptor(Deno.env, "get")!;
  const pair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const key = {
    ...await crypto.subtle.exportKey("jwk", pair.publicKey),
    kid: "test-only-key",
    alg: "RS256",
  };
  let handler: Handler | undefined;
  let mode = "invalid_grant";
  let job: Record<string, unknown> | null = null;
  let paths: string[] = [];
  const id = "d87a392e-d3e2-450f-bc9f-73683ac42dc5";
  const user = "f21078d7-a49e-439f-9c18-437c9bb53304";
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  async function identityToken() {
    const payload = {
      iss: "https://appleid.apple.com",
      aud: mode === "wrong_audience" ? "wrong" : "test.app",
      exp: mode === "expired" ? 1 : Math.floor(Date.now() / 1000) + 300,
      sub: mode === "wrong_subject" ? "other-apple-user" : "apple-user",
    };
    const input = `${encoded({ alg: "RS256", kid: key.kid })}.${
      encoded(payload)
    }`;
    const signature = new Uint8Array(
      await crypto.subtle.sign(
        "RSASSA-PKCS1-v1_5",
        pair.privateKey,
        new TextEncoder().encode(input),
      ),
    );
    if (mode === "bad_signature") signature[0] ^= 0xff;
    return `${input}.${b64(signature)}`;
  }
  try {
    Object.defineProperty(Deno.env, "get", {
      configurable: true,
      enumerable: env.enumerable,
      writable: true,
      value: (name: string) =>
        ({
          SUPABASE_URL: "https://deletion-test.invalid",
          SUPABASE_SERVICE_ROLE_KEY: "fake-service-key",
          APPLE_CLIENT_ID: "test.app",
          APPLE_CLIENT_SECRET: "fake-client-secret",
          DELETION_STATUS_SECRET: "test-only-secret-at-least-32-bytes-long",
        } as Record<string, string>)[name],
    });
    Object.defineProperty(Deno, "serve", {
      configurable: true,
      enumerable: serve.enumerable,
      writable: true,
      value: (value: Handler) => {
        handler = value;
      },
    });
    globalThis.fetch = async (input) => {
      const url = new URL(
        input instanceof Request ? input.url : input.toString(),
      );
      paths.push(url.pathname);
      const anonymousUser = {
        id: user,
        is_anonymous: true,
        app_metadata: { provider: "anonymous", providers: ["anonymous"] },
        identities: [],
      };
      if (url.pathname === "/auth/v1/user") {
        if (mode === "anonymous") return json(anonymousUser);
        return json({
          id: user,
          app_metadata: { provider: "apple", providers: ["apple"] },
          identities: [{
            provider: "apple",
            identity_data: { sub: "apple-user" },
          }],
        });
      }
      if (url.pathname === "/auth/keys") return json({ keys: [key] });
      if (url.pathname === "/auth/token") {
        if (mode === "network") throw new Error("test network failure");
        if (mode === "invalid_grant") {
          return json({ error: "invalid_grant" }, 400);
        }
        return json({
          access_token: "test-access",
          refresh_token: "test-refresh",
          id_token: await identityToken(),
        });
      }
      if (url.pathname === "/auth/revoke") {
        return json({}, mode === "revoke_failure" ? 503 : 200);
      }
      if (url.pathname === `/auth/v1/admin/users/${user}`) {
        return json(mode === "anonymous" ? anonymousUser : {});
      }
      const rpc = url.pathname.replace("/rest/v1/rpc/", "");
      if (rpc === "mora_get_account_deletion_status") return json(job);
      if (rpc === "mora_begin_account_deletion") {
        job ??= {
          requestId: id,
          jobId: id,
          userId: user,
          status: "requested",
          appleRevokedAt: null,
          dataPurgedAt: null,
          authDeletedAt: null,
          nextAttemptAt: null,
          requiresAppleReauth: false,
        };
        return json(job);
      }
      if (!job) throw new Error("mutation before begin");
      if (rpc === "mora_claim_account_deletion") {
        job = { ...job, status: "running", claimed: true };
      } else if (rpc === "mora_mark_account_deletion_apple_revoked") {
        job.appleRevokedAt = "2026-10-13T00:00:00Z";
      } else if (rpc === "mora_purge_account_deletion_data") {
        job.dataPurgedAt = "2026-10-13T00:00:00Z";
      } else if (rpc === "mora_complete_account_deletion") {
        job.status = "completed";
      } else if (rpc === "mora_mark_account_deletion_retry") {
        job = { ...job, status: "retry_wait", requiresAppleReauth: true };
      } else throw new Error(`unexpected offline request ${url.pathname}`);
      return json(job);
    };
    await import("./index.ts");
    async function invoke(
      body: Record<string, unknown> = {
        requestId: id,
        appleAuthorizationCode: "test-code",
      },
    ) {
      paths = [];
      const token = `${encoded({ alg: "test" })}.${
        encoded({ iat: Math.floor(Date.now() / 1000) })
      }.fake`;
      return await handler!(
        new Request("https://edge-test.invalid/delete-account", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify(body),
        }),
      );
    }
    for (
      const failure of [
        "invalid_grant",
        "wrong_subject",
        "wrong_audience",
        "expired",
        "bad_signature",
        "network",
      ]
    ) {
      await t.step(
        `${failure} creates no lock or deletion mutation`,
        async () => {
          mode = failure;
          job = null;
          const response = await invoke();
          assertEquals(response.status, failure === "network" ? 503 : 409);
          assertEquals(job, null);
          assertEquals(
            paths.filter((p) => p.startsWith("/rest/v1/rpc/")).every((p) =>
              p.endsWith("mora_get_account_deletion_status")
            ),
            true,
          );
          assertEquals(paths.includes("/auth/revoke"), false);
        },
      );
    }
    await t.step(
      "valid proof precedes begin; durable lock precedes revoke and purge",
      async () => {
        mode = "success";
        job = null;
        assertEquals((await invoke()).status, 200);
        const at = (path: string) => paths.indexOf(path);
        assertEquals(
          at("/auth/token") < at("/rest/v1/rpc/mora_begin_account_deletion"),
          true,
        );
        assertEquals(
          at("/rest/v1/rpc/mora_claim_account_deletion") < at("/auth/revoke"),
          true,
        );
        assertEquals(
          at("/auth/revoke") <
            at("/rest/v1/rpc/mora_purge_account_deletion_data"),
          true,
        );
        assertEquals(
          (job as Record<string, unknown> | null)?.status,
          "completed",
        );
      },
    );
    await t.step(
      "revocation failure keeps a resumable job and never purges",
      async () => {
        mode = "revoke_failure";
        job = null;
        const response = await invoke();
        assertEquals(response.status, 409);
        assertEquals(
          (await response.json()).error.code,
          "apple_reauth_required",
        );
        assertEquals(
          (job as Record<string, unknown> | null)?.status,
          "retry_wait",
        );
        assertEquals(
          paths.includes("/rest/v1/rpc/mora_purge_account_deletion_data"),
          false,
        );
      },
    );
    await t.step(
      "already revoked job resumes without reusing an Apple code",
      async () => {
        mode = "invalid_grant";
        job = {
          requestId: id,
          jobId: id,
          userId: user,
          status: "retry_wait",
          appleRevokedAt: "2026-10-13T00:00:00Z",
          dataPurgedAt: null,
        };
        assertEquals((await invoke()).status, 200);
        assertEquals(paths.includes("/auth/token"), false);
        assertEquals(paths.includes("/auth/revoke"), false);
      },
    );
    await t.step(
      "verified anonymous account deletes without Apple proof or revoke",
      async () => {
        mode = "anonymous";
        job = null;
        assertEquals((await invoke({ requestId: id })).status, 200);
        assertEquals(paths.includes("/auth/token"), false);
        assertEquals(paths.includes("/auth/revoke"), false);
        assertEquals(
          (job as Record<string, unknown> | null)?.status,
          "completed",
        );
      },
    );
    await t.step(
      "Apple account cannot skip Apple proof with the anonymous shape",
      async () => {
        mode = "success";
        job = null;
        assertEquals((await invoke({ requestId: id })).status, 400);
        assertEquals(job, null);
        assertEquals(paths.includes("/auth/token"), false);
      },
    );
    await t.step(
      "anonymous account cannot send an Apple code",
      async () => {
        mode = "anonymous";
        job = null;
        assertEquals((await invoke()).status, 403);
        assertEquals(job, null);
      },
    );
  } finally {
    globalThis.fetch = originalFetch;
    Object.defineProperty(Deno, "serve", serve);
    Object.defineProperty(Deno.env, "get", env);
  }
});
