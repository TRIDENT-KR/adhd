// 테스트 전용: Apple과 같은 모양의 인증서 체인(root P-384 → WWDR 표식 intermediate →
// receipt-signing 표식 leaf P-256)을 WebCrypto로 만들고 ES256 x5c JWS를 서명한다.
// 배포 함수에서 import하지 않는다.
import "npm:reflect-metadata@0.2.2";
import * as x509 from "npm:@peculiar/x509@2.1.0";

const DAY = 86_400_000;
const P384 = { name: "ECDSA", namedCurve: "P-384" };
const P256 = { name: "ECDSA", namedCurve: "P-256" };
const ECDSA_SHA384 = { name: "ECDSA", hash: "SHA-384" };
export const OID_LEAF = "1.2.840.113635.100.6.11.1";
export const OID_WWDR = "1.2.840.113635.100.6.2.1";

export interface Issued {
  cert: x509.X509Certificate;
  keys: CryptoKeyPair;
}

const marker = (oid: string) => new x509.Extension(oid, false, new Uint8Array([0x05, 0x00]));
const caExtensions = () => [
  new x509.BasicConstraintsExtension(true, 0, true),
  new x509.KeyUsagesExtension(x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign, true),
];
const generate = (alg: EcKeyGenParams) =>
  crypto.subtle.generateKey(alg, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;

export const der = (cert: x509.X509Certificate) => new Uint8Array(cert.rawData);
const b64 = (cert: x509.X509Certificate) => btoa(String.fromCharCode(...der(cert)));
export const b64u = (x: string | Uint8Array) =>
  btoa(String.fromCharCode(...(typeof x === "string" ? new TextEncoder().encode(x) : x)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export async function makeRoot(cn: string): Promise<Issued> {
  const keys = await generate(P384);
  const cert = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: `CN=${cn}`,
    notBefore: new Date(Date.now() - DAY),
    notAfter: new Date(Date.now() + 3650 * DAY),
    signingAlgorithm: ECDSA_SHA384,
    keys,
    extensions: caExtensions(),
  });
  return { cert, keys };
}

export async function issue(
  issuer: Issued,
  cn: string,
  options: { ca: boolean; oid?: string; notBefore?: Date; notAfter?: Date },
): Promise<Issued> {
  const keys = await generate(options.ca ? P384 : P256);
  const extensions: x509.Extension[] = options.ca ? caExtensions() : [
    new x509.BasicConstraintsExtension(false, undefined, true),
    new x509.KeyUsagesExtension(x509.KeyUsageFlags.digitalSignature, true),
  ];
  if (options.oid) extensions.push(marker(options.oid));
  const cert = await x509.X509CertificateGenerator.create({
    serialNumber: crypto.randomUUID().replace(/-/g, "").slice(0, 16),
    subject: `CN=${cn}`,
    issuer: issuer.cert.subject,
    notBefore: options.notBefore ?? new Date(Date.now() - DAY),
    notAfter: options.notAfter ?? new Date(Date.now() + 365 * DAY),
    signingAlgorithm: ECDSA_SHA384,
    publicKey: keys.publicKey,
    signingKey: issuer.keys.privateKey,
    extensions,
  });
  return { cert, keys };
}

export async function signJws(
  payload: unknown,
  chain: { leaf: Issued; intermediate: Issued; root: Issued },
  options: { alg?: string; x5c?: x509.X509Certificate[] } = {},
): Promise<string> {
  const x5c = options.x5c ?? [chain.leaf.cert, chain.intermediate.cert, chain.root.cert];
  const input = `${b64u(JSON.stringify({ alg: options.alg ?? "ES256", x5c: x5c.map(b64) }))}.${
    b64u(JSON.stringify(payload))
  }`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    chain.leaf.keys.privateKey,
    new TextEncoder().encode(input),
  );
  return `${input}.${b64u(new Uint8Array(signature))}`;
}

/** Apple 모양의 정상 체인 하나. rootDer를 pinnedRootsDer로 넘기면 된다. */
export async function appleLikeChain() {
  const root = await makeRoot("Test Root CA - G3");
  const intermediate = await issue(root, "Test WWDR G6", { ca: true, oid: OID_WWDR });
  const leaf = await issue(intermediate, "Test Receipt Signing", { ca: false, oid: OID_LEAF });
  return { root, intermediate, leaf, rootDer: der(root.cert) };
}

export const SAMPLE_NOW = new Date("2026-09-24T09:00:00Z");
const HOUR = 3_600_000;

/** 우리 앱의 정상 월간 구독 거래 payload (SAMPLE_NOW 기준 활성). */
export function sampleTransaction(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    transactionId: "2000000999000002",
    originalTransactionId: "2000000999000001",
    bundleId: "trident-KR.ADHD",
    productId: "com.TRIDENT.ADHD.monthly",
    type: "Auto-Renewable Subscription",
    inAppOwnershipType: "PURCHASED",
    environment: "Sandbox",
    appAccountToken: "6F9619FF-8B86-D011-B42D-00C04FC964FF",
    purchaseDate: SAMPLE_NOW.getTime() - HOUR,
    expiresDate: SAMPLE_NOW.getTime() + 30 * 24 * HOUR,
    signedDate: SAMPLE_NOW.getTime(),
    ...over,
  };
}
