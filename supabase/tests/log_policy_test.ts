// QA-005 재발 방지: Edge Function 로그에는 식별자·길이·상태 코드만 남긴다.
// 전사문, 모델 원문, 이메일, 요청 본문처럼 사용자 내용이 담길 수 있는 값은
// console.* 인자로 들어가는 순간 이 테스트가 실패한다.
import { assertEquals } from "jsr:@std/assert@1";
import { fromFileUrl, relative } from "jsr:@std/path@1";
import { walk } from "jsr:@std/fs@1/walk";

const FUNCTIONS_DIR = fromFileUrl(new URL("../functions/", import.meta.url));

/** 값 경로의 마지막 조각이 이것이면 내용이 아니라 메타데이터다. */
const SAFE_LEAVES = new Set([
  "length",
  "status",
  "code",
  "requestId",
  "traceId",
  "notificationType",
  "subtype",
]);

/** 통째로 허용하는 값 경로. */
const SAFE_PATHS = new Set([
  "traceId",
  "requestId",
  "logicalRequestId",
  "startedAt",
  "name", // delete-account rpc()의 RPC 함수 이름
  "action", // storekit-sync: "register" | "rebind"로 검증된 값
  "notificationType", // Apple 알림 종류: ^[A-Z_]{1,64}$로 검증된 값
  "subtype",
  "result", // DB가 돌려주는 처리 결과 코드
  "outputCount",
  "Math.round",
  "performance.now",
  "null",
  "undefined",
  "true",
  "false",
]);

type Violation = { file: string; line: number; value: string };

/** `console.x(` 이후 괄호 짝이 맞는 인자 문자열을 뽑는다. */
function consoleCalls(source: string): { args: string; line: number }[] {
  const calls: { args: string; line: number }[] = [];
  const pattern = /console\.(log|info|warn|error|debug)\s*\(/g;
  for (const match of source.matchAll(pattern)) {
    let depth = 1;
    let i = match.index! + match[0].length;
    const start = i;
    let quote: string | null = null;
    for (; i < source.length && depth > 0; i++) {
      const ch = source[i];
      if (quote) {
        if (ch === "\\") i++;
        else if (ch === quote) quote = null;
        continue;
      }
      if (ch === '"' || ch === "'" || ch === "`") quote = ch;
      else if (ch === "(") depth++;
      else if (ch === ")") depth--;
    }
    calls.push({
      args: source.slice(start, i - 1),
      line: source.slice(0, match.index).split("\n").length,
    });
  }
  return calls;
}

/**
 * 문자열 리터럴을 지운다. 단, 템플릿 문자열의 `${...}` 식은 값이므로 남긴다.
 * (배포본 delete-account가 `${user.email}`로 이메일을 남겼던 경로)
 */
function stripStrings(args: string): string {
  let out = "";
  for (let i = 0; i < args.length; i++) {
    const ch = args[i];
    if (ch === '"' || ch === "'") {
      for (i++; i < args.length && args[i] !== ch; i++) if (args[i] === "\\") i++;
      out += '""';
    } else if (ch === "`") {
      for (i++; i < args.length && args[i] !== "`"; i++) {
        if (args[i] === "\\") {
          i++;
        } else if (args[i] === "$" && args[i + 1] === "{") {
          let depth = 1;
          const start = i + 2;
          for (i += 2; i < args.length && depth > 0; i++) {
            if (args[i] === "{") depth++;
            else if (args[i] === "}") depth--;
          }
          out += ` (${stripStrings(args.slice(start, i - 1))}) `;
          i--;
        }
      }
      out += '""';
    } else {
      out += ch;
    }
  }
  return out;
}

/** 인자에서 문자열 리터럴과 객체 키를 지우고 값으로 쓰인 경로만 남긴다. */
function valuePaths(args: string): string[] {
  const withoutStrings = stripStrings(args);
  const withoutKeys = withoutStrings.replace(/([{,]\s*)[A-Za-z_$][\w$]*\s*:/g, "$1");
  return [...withoutKeys.matchAll(/[A-Za-z_$][\w$]*(?:\s*\??\.\s*[A-Za-z_$][\w$]*)*/g)]
    .map((m) => m[0].replace(/\s|\?/g, ""));
}

function isSafe(path: string): boolean {
  if (SAFE_PATHS.has(path)) return true;
  const leaf = path.split(".").at(-1)!;
  return path.includes(".") && SAFE_LEAVES.has(leaf);
}

async function findViolations(): Promise<Violation[]> {
  const violations: Violation[] = [];
  for await (
    const entry of walk(FUNCTIONS_DIR, {
      exts: [".ts"],
      // 레거시 로컬 도구(test/)와 테스트 파일은 배포되지 않는다.
      skip: [/_test\.ts$/, /[\\/]test[\\/]/, /[\\/]eval[\\/]/],
    })
  ) {
    const source = await Deno.readTextFile(entry.path);
    for (const call of consoleCalls(source)) {
      for (const path of valuePaths(call.args)) {
        if (!isSafe(path)) {
          violations.push({
            file: relative(FUNCTIONS_DIR, entry.path),
            line: call.line,
            value: path,
          });
        }
      }
    }
  }
  return violations;
}

Deno.test("Edge Function 로그에는 허용된 메타데이터만 들어간다", async () => {
  assertEquals(await findViolations(), []);
});

Deno.test("정책 검사기가 민감 값을 실제로 잡아낸다", () => {
  const sample = `
    console.log("gemini_raw", { traceId, body: responseText });
    console.info("user", user.email, { inputLength: text.length });
    console.error("ok", { requestId: result.requestId, code: err.code });
    console.log(\`Deleting \${user.id} (\${user.email}) len=\${text.length}\`);
  `;
  const flagged = consoleCalls(sample)
    .flatMap((call) => valuePaths(call.args))
    .filter((path) => !isSafe(path));
  assertEquals(flagged, ["responseText", "user.email", "user.id", "user.email"]);
});
