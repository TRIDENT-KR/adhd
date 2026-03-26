# LLM 프롬프트 테스트 플로우

`analyze-task` Edge Function의 시스템 프롬프트를 로컬에서 빠르게 반복 테스트하기 위한 도구입니다.

## 파일 구조

```
test/
├── README.md          ← 이 파일
├── sample_inputs.json ← 테스트 케이스 모음 (TC001 ~ TC010)
├── run_test.ts        ← Deno 기반 테스트 실행기
├── run_test.mjs       ← Node.js 기반 테스트 실행기 (권장)
└── results/
    └── latest_run.json ← 최신 테스트 결과 (자동 생성)
```

## 사전 준비

1. [Node.js v24 이상 설치](https://nodejs.org/) (네이티브 fetch 사용)
2. Gemini API 키 발급 (Google AI Studio)

## 사용법

### 전체 테스트 케이스 실행 (Node.js)
```bash
GEMINI_API_KEY=<your_key> node supabase/functions/analyze-task/test/run_test.mjs
```

### 전체 테스트 케이스 실행 (Deno)
```bash
GEMINI_API_KEY=<your_key> deno run --allow-net --allow-read --allow-env supabase/functions/analyze-task/test/run_test.ts
```

## 테스트 케이스 설명 (English Version)

현재 테스트 케이스는 영어 시나리오로 업데이트되었습니다 (`sample_inputs.json` 참고).
ADHD 사용자의 특성(말 번복, 여러 의도 혼합 등)을 반영한 10개의 케이스를 검증합니다.

## 검증 항목

각 테스트 케이스는 자동으로 다음을 검증합니다:
- `action`: `add` / `delete` / `update` 중 하나인지
- `task`: 빈 문자열이 아닌지
- `time`: `null` 또는 `"hh:mm AM/PM"` 형식인지
- `category`: `Routine` 또는 `Appointment` 중 하나인지
- 케이스별 기대값 (expected action, category, 개수 등)

## 프롬프트 수정 방법

1. `run_test.mjs` (또는 `run_test.ts`) 파일 상단의 `SYSTEM_PROMPT` 상수를 수정
2. 테스트 실행하여 결과 확인
3. 만족스러운 프롬프트가 나오면 `../index.ts`의 `systemInstruction`에 반영
