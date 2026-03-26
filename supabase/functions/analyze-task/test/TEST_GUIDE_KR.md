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

## 5. 실행 명령어

```bash
# Node.js 환경 (권장)
GEMINI_API_KEY=<키> node supabase/functions/analyze-task/test/run_test.mjs

# Deno 환경
GEMINI_API_KEY=<키> deno run --allow-net --allow-read --allow-env supabase/functions/analyze-task/test/run_test.ts
```
