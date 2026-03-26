# LLM 프롬프트 테스트 시스템 기술 설계 문서 (Technical Architecture)

이 문서는 `analyze-task` Edge Function의 프롬프트 품질을 검증하기 위한 테스트 자동화 시스템의 기술적 구조와 데이터 흐름을 상세히 설명합니다.

---

## 1. 시스템 아키텍처 (System Architecture)

본 테스트 시스템은 **데이터 중심(Data-Driven)** 설계 방식을 따르며, 테스트 케이스와 실행 엔진이 완전히 분리된 구조를 가집니다.

```text
[ Input Layer ]
      |
      v
[ sample_inputs.json ] ----> [ Test Runner ]
                                     |
                                     v
                        [ Execution Layer (Runner) ]
                                     |
                                     v
                        { API Request: Gemini 2.0 Flash }
                                     |
                                     v
                        [ LLM Analysis & JSON Extraction ]
                                     |
                                     v
                        [ Validation & Logic Layer ]
                                     |
                                     v
                        [ Sanitization & Cleaning ]
                                     |
                                     v
                        [ Validation Logic (3-Step Check) ]
                                     |
          -------------------------------------------------------
          |                                                     |
  { PASS Criteria }                                     { FAIL Criteria }
          |                                                     |
          v                                                     v
[ Green CLI Output ]                                  [ Red Error Details ]
          |                                                     |
          --------------------------+----------------------------
                                    |
                                    v
                        [ latest_run.json Storage ]
```

---

## 2. 모듈별 상세 설명 (Internal Modules)

### 2.1 데이터셋 (`sample_inputs.json`)
- **Key Features**: 독립적인 테스트 시나리오 정의.
- **Attributes**: `id`, `description`, `input` (사용자 발화), `expected` (기대 행위 및 카테고리), `expected_count` (결과 리스트 길이).

### 2.2 실행 엔진 (`run_test.mjs` / `run_test.ts`)
- **Core Functionality**: 
  - `Node.js` 및 `Deno` 멀티 런타임 지원.
  - 비동기 순차 처리를 통한 API Rate-Limit 방지 (500ms 딜레이).
  - 결과값 시각화 (ANSI Color 활용).

### 2.3 검증 엔진 (`validateResult`)
- **Hierarchy Validation**: 
  1. **Schema Check**: 필수 키 및 데이터 타입(JSON Schema-like) 검사.
  2. **Count Check**: 추출된 작업 개수의 정합성 검증.
  3. **Logic Check**: 시나리오별 `expected` 데이터 기반 논리적 일치 여부 확인.

---

## 3. 데이터 처리 파이프라인 (Processing Pipeline)

1.  **Read & Load**: `sample_inputs.json`을 비동기로 로드하여 테스트 케이스 배열 생성.
2.  **Prompt Assembly**: `SYSTEM_PROMPT`와 `input` 텍스트를 결합하여 Gemini API 페이로드 구성.
3.  **LLM Inference**: `gemini-2.0-flash` 모델을 통한 추론 (Response MIME: `application/json` 고정).
4.  **Cleaning**: 응답 텍스트 내 Markdown 코드 블록(```) 제거 및 불필요한 공백 제거.
5.  **Schema Enforcement**: 
    - `Object` 형태일 경우 즉시 `Array`로 강제 변환.
    - 각 원소의 필드 값 유효성(Action, Category 등) 검증.
6.  **Report & Store**: 결과를 터미널에 출력하고 `./results/latest_run.json`에 영구 저장.

---

## 4. 환경 전략 (Environment Strategy)

본 시스템은 로컬 개발 환경(Development)과 클라우드 운영 환경(Production)의 차이를 명확히 구분하여 설계되었습니다.

| 환경 | 주요 역할 | 특징 |
| :--- | :--- | :--- |
| **Test (Local)** | 프롬프트 정합성 검증 | 순수 LLM 추출 성능에 집중, 고정 데이터셋 활용 |
| **Runtime (Edge)** | 실제 서비스 제공 | **방어 로직(Defense Logic)** 활성화, 실시간 모바일 요청 처리 |

### 4.1 생산 환경 방어 로직 (Production Defense)
실제 구동 환경인 `index.ts`에는 테스트 환경보다 강화된 예외 처리가 포함되어 있습니다:
- **자동 복구 (Self-Healing)**: `task` 필드 누락 시 원문을 잘라 자동 생성.
- **값 교정 (Correction)**: 유효하지 않은 `category` 값이 들어올 경우 기본값(`Routine`) 부여.
- **CORS 최적화**: Swift(iOS) 클라이언트와의 원활한 통신을 위한 네트워크 헤더 구성.

---

## 5. 확장성 및 유지보수 (Extensibility)

새로운 테스트 시나리오를 추가하려면 `sample_inputs.json`의 `test_cases` 배열에 새로운 객체만 정의하면 됩니다. 실행 엔진은 추가적인 코드 수정 없이 새로운 케이스를 자동으로 감지하고 검증합니다.
