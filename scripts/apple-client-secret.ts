// Apple 로그인 연결 해제(delete-account)에 쓰는 APPLE_CLIENT_SECRET(JWT)을 로컬에서 만든다.
// 키 파일(.p8)과 결과 JWT는 화면·채팅·Git에 남기지 말고 바로 Supabase secret으로 넘긴다.
//
//   supabase secrets set APPLE_CLIENT_SECRET="$(deno run --allow-read=<p8 경로> \
//     scripts/apple-client-secret.ts --team 5S3Y6973X6 --key-id <Key ID> --p8 <p8 경로>)" \
//     --project-ref nmjtswtqwwxxwiolgsnk
//
// JWT는 stdout으로만 나가고, 만료일은 stderr로 안내한다. Apple 허용 최대 유효기간은 약 6개월이다.

const MAX_SECONDS = 15_777_000;
const DEFAULT_CLIENT_ID = "trident-KR.ADHD";

function option(name: string): string | undefined {
  const index = Deno.args.indexOf(`--${name}`);
  return index >= 0 ? Deno.args[index + 1] : undefined;
}

function fail(message: string): never {
  console.error(message);
  Deno.exit(1);
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const team = option("team");
const keyID = option("key-id");
const p8Path = option("p8");
const clientID = option("client-id") ?? DEFAULT_CLIENT_ID;
const days = Number(option("days") ?? "180");

if (!team || !/^[A-Z0-9]{10}$/.test(team)) fail("--team 에 10자리 Team ID를 넣어 주세요.");
if (!keyID || !/^[A-Z0-9]{10}$/.test(keyID)) fail("--key-id 에 10자리 Key ID를 넣어 주세요.");
if (!p8Path) fail("--p8 에 Apple에서 받은 AuthKey_XXXXXXXXXX.p8 경로를 넣어 주세요.");
const lifetime = Math.floor(days * 86_400);
if (!Number.isFinite(days) || lifetime <= 0 || lifetime > MAX_SECONDS) {
  fail("--days 는 1~182 사이여야 합니다. Apple은 6개월을 넘는 client secret을 받지 않습니다.");
}

const pem = await Deno.readTextFile(p8Path);
const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
if (!body) fail("p8 파일에서 키를 읽지 못했습니다.");
const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
const key = await crypto.subtle.importKey(
  "pkcs8",
  der,
  { name: "ECDSA", namedCurve: "P-256" },
  false,
  ["sign"],
);

const now = Math.floor(Date.now() / 1000);
const encoder = new TextEncoder();
const header = base64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: keyID })));
const payload = base64url(encoder.encode(JSON.stringify({
  iss: team,
  iat: now,
  exp: now + lifetime,
  aud: "https://appleid.apple.com",
  sub: clientID,
})));
// WebCrypto ECDSA 서명은 JWS ES256이 요구하는 r||s(64바이트) 형식이다.
const signature = new Uint8Array(await crypto.subtle.sign(
  { name: "ECDSA", hash: "SHA-256" },
  key,
  encoder.encode(`${header}.${payload}`),
));

console.log(`${header}.${payload}.${base64url(signature)}`);
console.error(
  `만료: ${new Date((now + lifetime) * 1000).toISOString().slice(0, 10)} — 그 전에 다시 만들어 secret을 갱신하세요.`,
);
