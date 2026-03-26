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

## 5. 상세 기술 정보 (Technical Docs)

테스트 시스템의 **시스템 아키텍처**, **데이터 흐름 분석**, **PASS/FAIL 판정 기준** 및 **서비스 환경과의 기술적 차이** 등에 대한 심층적인 정보는 아래 문서를 참고하세요.

- [LLM 테스트 기술 설계 문서 (LLM_TEST_ARCHITECTURE_KR.md)](./LLM_TEST_ARCHITECTURE_KR.md)

---

## 6. 실행 명령어

```bash
# Node.js 환경 (권장)
GEMINI_API_KEY=<키> node supabase/functions/analyze-task/test/run_test.mjs

# Deno 환경
GEMINI_API_KEY=<키> deno run --allow-net --allow-read --allow-env supabase/functions/analyze-task/test/run_test.ts
```
