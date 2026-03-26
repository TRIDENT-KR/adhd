# LLM 프롬프트 테스트 시스템 가이드

이 문서는 `analyze-task` Edge Function의 핵심 로직인 **ADHD 맞춤형 작업 추출 프롬프트**를 로컬 환경에서 쉽고 빠르게 검증하기 위해 설계된 테스트 시스템에 대해 설명합니다.

---

## 1. 테스트 시스템 목적

ADHD 사용자의 음성 데이터는 일반적인 명령어와 달리 다음과 같은 특징을 가집니다:
- **말 번복**: "아니 3시가 아니라 4시로 해줘"
- **횡설수설**: "그게 뭐였더라... 아 그래, 물 마시는 루틴 넣어줘"
- **복합 의도**: 작업 추가, 삭제, 수정을 한 문장에 섞어서 말함

이러한 복잡한 입력을 정확하게 구조화된 JSON 데이터로 변환하는 **프롬프트의 성능을 측정하고 개선**하는 것이 이 테스트 도구의 핵심 목적입니다.

---

## 2. 시스템 구성 요소

### 📂 `sample_inputs.json` (데이터셋)
테스트에 사용되는 10개의 핵심 시나리오가 들어있습니다.
- **TC001~TC002**: 기본적인 루틴 및 약속 추가
- **TC003~TC004**: ADHD 특화 (말 번복, 중간에 생각 바뀜) 검증
- **TC009~TC010**: 노이즈 섞인 입력 및 복합 요청 처리

### 🏃 `run_test.mjs` / `run_test.ts` (테스트 러너)
데이터셋을 읽어 실제 Gemini API에 요청을 보내고 결과를 검증하는 엔진입니다.
- `run_test.mjs`: Node.js(v24 이상) 환경용 (권장)
- `run_test.ts`: Deno 환경용

---

## 3. 테스트 작동 원리

테스트가 실행되면 다음 단계가 진행됩니다:

### STEP 1: Gemini API 호출
- 각 테스트 케이스의 `input` 텍스트를 `SYSTEM_PROMPT`와 함께 Gemini 모델(`gemini-2.0-flash`)에 전달합니다.
- 이때 모델은 **JSON 배열 형식**으로만 응답하도록 강제됩니다.

### STEP 2: 데이터 정제 및 파싱
- 모델이 반환한 텍스트에서 Markdown 코드 블록(```json) 등을 제거하고 순수 JSON 객체로 변환합니다.

### STEP 3: 자동 검증 (Validation Logic)
파싱된 결과값이 아래 기준을 만족하는지 자동으로 체크합니다:
1. **필수 키 검증**: `action`, `task`, `time`, `category` 키가 모두 존재하는지
2. **값의 유효성**: 
   - `action`이 `add`, `delete`, `update` 중 하나인가?
   - `category`가 `Routine` 또는 `Appointment` 중 하나인가?
   - `time`이 `null`이거나 `"hh:mm AM/PM"` 형식인가?
3. **기대값(Expected) 비교**: `sample_inputs.json`에 정의된 기대 개수나 특정 값과 일치하는지 확인합니다.

### STEP 4: 결과 리포트
- 터미널에 **[PASS]** (녹색) 또는 **[FAIL]** (적색) 표시와 함께 응답 시간(Latency)을 출력합니다.
- 실패 시 어떤 검증 단계에서 문제가 발생했는지(예: "결과 개수 불일치") 상세 사유를 보여줍니다.

---

## 4. 테스트 활용 및 프롬프트 개선 워크플로우

만약 특정 케이스에서 **FAIL**이 발생하거나 성능을 더 높이고 싶다면 다음 과정을 따르세요.

1.  **프롬프트 수정**: `run_test.mjs` (또는 `.ts`) 상단의 `SYSTEM_PROMPT` 변수 내용을 수정합니다.
2.  **테스트 재실행**: 수정한 프롬프트가 기존 10개 케이스에 부정적인 영향을 주지 않는지 확인합니다.
3.  **결과 반영**: 모든 테스트를 통과하는 최적의 프롬프트를 찾았다면, 이를 상위 디렉토리의 실제 서비스 코드인 `../index.ts`에 복사하여 배포합니다.

---

## 5. 데이터 처리 및 파싱 로직의 기술적 분석

테스트 환경과 실제 구동 환경은 단순히 실행 위치만 다른 것이 아니라, **데이터의 정제(Sanitization) 및 예외 처리(Defense Logic)** 단계에서 결정적인 기술적 차이가 존재합니다.

### 5.1 데이터 흐름 분석 (System Flow)

1.  **테스트 환경 (Dry Run)**:
    - `Local JSON` (Source) → `Test Runner` → `Gemini API` → `Simple JSON.parse` → `Console Output`
    - 목적: 프롬프트의 **순수 추출 성능** 검증

2.  **실제 구동 환경 (Production)**:
    - `iOS App (HTTP POST)` → `Supabase Edge Runtime` → `index.ts` → `Gemini API` → **`Production Defense Logic`** → `Response (HTTP 200)`
    - 목적: 모바일 앱의 **안정적 구동 및 Swift 데이터 모델 호환성** 보장

### 5.2 기술적 처리 차이 (Technical Handling)

| 기술 요소 | 테스트 환경 (`run_test.mjs/ts`) | 실제 구동 환경 (`index.ts`) |
| :--- | :--- | :--- |
| **JSON 추출** | `rawText`를 단순히 파싱하여 리스트 출력 | AI 응답에서 Markdown(```json) 제거 및 엄격한 트림(Trim) 적용 |
| **배열 강제화** | 배열이 아니면 오류로 간주 (FAIL) | **방어 코드**: AI가 단일 객체 `{...}` 반환 시 `[parsedData]`로 자동 래핑 |
| **Task 필드 보정** | 비어있으면 이슈 보고 (FAIL) | **데이터 복구**: AI가 할 일 이름을 놓칠 경우, **입력 문장의 앞부분 20자**를 활용해 할 일 자동 생성 |
| **Category 무결성** | 값 불일치 시 이슈 보고 (FAIL) | **런타임 교정**: 스키마 외의 값이 들어오면 강제로 `"Routine"`으로 수정하여 앱 크래시 방지 |
| **Action 기본값** | 값 누락 시 이슈 보고 (FAIL) | **누락 방지**: `action` 값이 없을 경우 기본값 `"add"`를 자동 할당 |
| **통신 프로토콜** | 직접 Fetch (No Headers) | **CORS/Swift 최적화**: iOS 앱과의 연동을 위해 `authorization`, `x-client-info` 등 복합 헤더 허용 |

### 5.3 왜 실제 환경에만 추가 로직이 있는가?

iOS 앱(Swift)은 서버 응답을 받을 때 강력한 타입 체크를 수행합니다. 만약 AI가 실수로 `task`를 `null`로 보냈을 경우, 테스트 환경에서는 단순히 "실패"로 기록되지만, **실제 앱에서는 파싱 실패로 인해 서비스 전체가 멈출 수 있습니다.**

따라서 실제 작동 환경인 `index.ts`에는 **"AI가 완벽하지 않을 수 있다"**는 전제하에, 데이터의 형태를 강제로 교정하여 앱에 전달하는 **런타임 보정 레이어**가 포함되어 있습니다.

---

## 6. 실행 명령어

```bash
# Node.js 환경 (권장)
GEMINI_API_KEY=<키> node supabase/functions/analyze-task/test/run_test.mjs

# Deno 환경
GEMINI_API_KEY=<키> deno run --allow-net --allow-read --allow-env supabase/functions/analyze-task/test/run_test.ts
```
