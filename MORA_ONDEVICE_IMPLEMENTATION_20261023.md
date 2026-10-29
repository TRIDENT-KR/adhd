# MORA 정본 기반 구현 기록 — 2026-10-23

> 2026-10-29 후속 통합 및 회귀 검증은 [통합 검증 기록](research/integration-20261029/validation.md)을 따릅니다. 아래는 10월 23일 당시 기록입니다.

기준: [AI·온디바이스 처리 정본 — 자동 하이브리드 결정](https://app.notion.com/p/4018320bd64b81fc8b22d40317178739)

## 반영한 동작

새 분석 진입점은 계정·연령·현재 저장소 권한을 먼저 확인한다. 개발 빌드에서는 지원되는 명확한 단일 약속을 Swift로 분석하고, 나머지는 기존 Claude 우선 → Gemini Flash Lite 대체 서버 경로로 전달한다. 클라우드 전송 동의·네트워크·무료 횟수 검사는 원격 분기에만 적용한다. 사용자는 엔진 선택이나 모델 다운로드 설정을 하지 않는다.

로컬 결과는 저장 전에 항상 기존 확인 카드를 거친다. 로컬 분석은 서버에 접속하지 않고 서버 사용량을 차감하지 않는다. 클라우드 분석이 불가능하면 입력을 그대로 두며, 연결이 돌아와도 자동 업로드하지 않는다.

**출시 활성화 상태:** 로컬 규칙 분석은 DEBUG에서 활성화했다. Release에서는 독립 평가·실물 iPhone 검증 전까지 비활성이다. 이는 정본의 도입 조건을 코드로 고정한 것이며 사용자 설정으로 노출하지 않는다. 이번 작업에서 Apple 생성 모델 호출은 연결하지 않았다. Apple 모델의 가용성만으로 의미 정확성이나 기기별 성능을 인정하지 않는다. 공개 모델·추가 런타임·대규모 가중치도 앱에 넣지 않았다.

## 로컬 처리의 정확한 범위

지원 언어는 한국어·영어·일본어다. 오늘/내일/ISO 날짜, 명시적인 오전·오후 시각, 검토한 약속 명사의 조합 전체가 일치해야 한다. 날짜는 요청 시점의 Gregorian Calendar와 시간대로 계산한다.

예:

- `내일 오후 3시 치과 추가해줘.`
- `Add Dentist tomorrow at 3 PM.`
- `明日午後3時に歯医者を追加して`

현재 명사 목록은 언어별 12개이며 `TaskAnalysisRouter.swift`의 `LocalTaskParser.titles`에 고정되어 있다. 제목 원문과 시간 표현의 UTF-16 위치를 보존한다. 임의 제목, 불명확한 시각, 정정·부정·예외·인용·복수 명령·반복·타 시간대는 부분 해석하지 않고 클라우드로 넘긴다. 없는 날짜, 지난 시각, DST gap/overlap도 로컬에서 임의 보정하지 않는다.

이 범위는 제한적인 빠른 처리 경로다. 일반적인 자연어 온디바이스 기능, 전 기기 완전 오프라인, 로컬 처리율 70%를 달성했다고 주장하지 않는다.

## 공통 검증과 실행 경계

- 알 수 없는 카테고리를 Routine으로 바꾸던 처리를 제거했다. 알려진 대소문자 변형만 정규화한다.
- 알 수 없는 명령/인자 키, 잘못된 날짜·시간·반복·알림 강도, 빈/과도하게 긴 문자열, 제어 문자를 거부한다. 이전 응답과의 호환을 위해 nullable 인자의 생략은 허용한다.
- 응답은 1~50개 명령으로 제한한다. 명확화·범위 밖 안내는 단독 응답이어야 한다. 안내에 실제 변경을 섞는 응답은 앱과 서버가 모두 거부한다.
- 서버는 이런 실패를 성공 차감으로 확정하지 않고 예약을 해제한다. 제공자 출력 검증 실패는 기존 Claude→Gemini 대체 로직을 따른다.
- 확인 카드에서 편집한 시간은 기기 표시 형식과 무관하게 `hh:mm AM/PM` 계약으로 저장한다.
- update/complete 대상 이름이 중복되면 첫 UUID를 고르지 않는다. 후보를 표시하고 사용자가 선택한 UUID·상태 스냅샷만 승인한다. 승인 후 변경된 대상은 기존 stale 재확인 경로로 돌린다. 기존 명시적 배치 삭제·전체 변경 확인 정책은 유지한다.
- 요청 ID·기준 시각·시간대·언어·계정 generation을 한 번만 캡처해 로컬과 클라우드 재시도에 공유한다. A→B→A 또는 로그아웃 후 재로그인도 이전 generation과 달라지므로 늦은 응답을 버린다.
- 사용자 취소·계정/저장소 무효화·시간대 변경 이후 결과를 저장하지 않는다. 서버 quota는 해당 클라우드 결과에만 붙이며 로컬 성공에 이전 quota 스냅샷을 재사용하지 않는다.

필드 검증은 모델의 의미 이해를 증명하지 않는다. 기존 클라우드의 모든 자연어 오류를 해결했다는 의미는 아니다.

## 음성 전사

Speech의 `supportsOnDeviceRecognition`을 확인한 뒤 `requiresOnDeviceRecognition = true`로 요청한다. 로컬 인식을 지원하지 않으면 오디오를 서버 인식으로 자동 대체하지 않고 글로 입력하도록 안내한다. 기본 마이크·Speech 권한 요청은 그대로다.

근거: [Apple requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition), [supportsOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).

## 변경 위치

- `ADHD/TaskAnalysisRouter.swift`: 요청 문맥, 엔진별 결과, 로컬 파서, 원격 분기, 출시 활성화 조건.
- `ADHD/HomeVoiceInterfaceView.swift`: 공통 분석 진입점, 강제 로컬 미리보기, 대상 선택, 초안 보존.
- `ADHD/CloudLLMManager.swift`: 고정 문맥을 사용한 재시도와 계정 generation 검사.
- `ADHD/Functions/LLMFunctionCall.swift`: 디코딩/실행 검증, 후보 선택.
- `ADHD/Functions/TaskManager+LLM.swift`: 동명 대상 거부·UUID 고정과 배치 검증.
- `ADHD/NotificationManager.swift`: 기존 AccountPreferences에 계정 generation 추가.
- `ADHD/VoiceInputManager.swift`: 로컬 음성 인식 조건.
- `ADHD/ADHDTests/TaskAnalysisTests.swift`, `LLMFunctionCallDecodingTests.swift`: 의미·상태·검증 회귀. 기존 `UrgencyClassificationTests.swift`, `DeleteByNameBatchTests.swift`의 입력도 실제 서버 필드·12시간 형식 계약에 맞췄다.
- `scripts/test-analysis-core.py`: 실제 Swift 소스와 같은 테스트를 임시 패키지로 추출하는 macOS 분석 핵심 검증 도구. 파서·라우터·검증기를 별도로 재구현하지 않는다.
- `supabase/functions/analyze-task/{validator.ts,validator_test.ts,analysis-service_test.ts,index.ts}`: 공통 응답 제약과 실패 시 미차감 검증.
- `ADHD/ADHD.xcodeproj/project.pbxproj`: 새 Swift 소스/테스트 등록.

기존 출시 전 Claude/Gemini 라우터·보안·UI 수정은 유지했다. 이번 작업의 새 서버 변경은 출력 계약 보강이며 운영 배포를 수행하지 않았다.

## 검증 기록

| 검사 | 결과 |
|---|---|
| 서버 Deno 테스트 | 84개 통과, 18개 하위 단계, 실패 0개 |
| `analyze-task/index.ts` TypeScript 검사 | 통과 |
| macOS 분석 핵심 테스트 | 2개 suite, 13개 테스트, 48개 매개변수 사례 통과 |
| iOS Simulator 신규 분석·실행 경계 테스트 | `TaskAnalysisTests`, `AnalysisExecutionBoundaryTests` 모두 통과 |
| 전체 iOS 회귀 테스트 | 첫 실행 140개 중 기존 입력 계약 관련 15개 issue. 해당 입력 수정 후 재실행은 테스트 러너 시작 전 멈춤으로 중단. 전체 통과 미확인 |
| Release Simulator 빌드 | 통과, arm64/x86_64 |
| `git diff --check` | 통과 |

새 테스트는 3개 언어의 명확한 단일 추가, 정정·부정·예외·인용 등 로컬 보류, DST gap/overlap, 자정·연도 경계, 전송 권한 차단, 고정 시간 문맥, 계정 A→B→A, 취소·늦은 결과, 중복 이름 선택과 stale target을 다룬다. macOS 추출 테스트는 SwiftUI·SwiftData·Speech 하드웨어·실제 서버 통신 검증을 대신하지 않는다. 이번 테스트 입력은 개발 회귀 자료이며 독립 의미 평가가 아니다.

초기 시뮬레이터 실행은 부팅/테스트 러너 문제로 중단됐다. 전용 시뮬레이터에서 실행한 뒤 기존 9개 테스트의 미지원 필드와 24시간 형식 입력 때문에 발생한 15개 issue를 수정했다. 검증 규칙을 완화하지 않았다. 수정 후 앱·테스트 빌드는 완료됐으나, 재실행이 테스트 시작 전 단계에서 장시간 멈춰 MORA의 실행 프로세스만 종료했다. 다른 프로젝트의 시뮬레이터 작업은 건드리지 않았다. 병렬 빌드의 DB 잠금 재시도도 테스트 실패와 구분했다. **수정 후 전체 iOS 회귀 통과는 후속 확인이 필요하다.**

재현 명령(프로젝트가 빌드 중간 경로를 공유하므로 Xcode 명령은 차례로 실행):

```bash
deno test --config supabase/deno.json --allow-read --allow-env=APPLE_BUNDLE_ID \
  supabase/functions/*/*_test.ts supabase/tests/*_test.ts
deno check --config supabase/deno.json supabase/functions/analyze-task/index.ts
python3 scripts/test-analysis-core.py /tmp/mora-analysis-core-tests
xcodebuild -project ADHD/ADHD.xcodeproj -scheme ADHD \
  -destination 'platform=iOS Simulator,name=Mora-OnDevice-QA-20261023,OS=26.5' \
  -derivedDataPath /tmp/mora-ondevice-impl-20261023/DerivedData \
  -parallel-testing-enabled NO -only-testing:ADHDTests test
xcodebuild -project ADHD/ADHD.xcodeproj -scheme ADHD -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/mora-ondevice-impl-20261023/DerivedData \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

검증 요약·소스 SHA256은 `research/ondevice-20261023/implementation-validation.json`에 보존한다. 상세 로컬 로그는 `/tmp/mora-ondevice-impl-20261023/`의 `deno-test-final.log`, `deno-check.log`, `core-tests-final.log`, `xcode-test-final.log`(첫 회귀 실행), `xcode-test-rerun-blocked.log`(수정 후 시작 지연), `xcode-release-build.log`에 있다. 임시 디렉터리의 상세 로그는 장기 보존을 보장하지 않는다.

## 출시 전에 남은 검증

1. 수정 후 전체 iOS 회귀 테스트를 통과시킨다. 사람 검수한 별도 KO/EN/JA 입력에서 의미 정확도와 유용한 로컬 처리 범위를 측정한다. 이번 회귀 입력을 독립 평가 자료로 재사용하지 않는다.
2. 격리된 4GB/6GB 실물 iPhone에서 Release 빌드의 cold/warm 지연, peak 메모리, 반복 사용 발열, 음성 동시 사용, 오프라인·취소·계정 전환 UI를 확인한다.
3. Apple 모델은 지원 기기·OS·언어별 의미 평가 및 실기기 비용 검증을 먼저 수행한다. 이후 제한된 기능만 별도 구현·활성화한다.
4. 검증 근거를 남긴 뒤 `TaskAnalysisRollout.localRulesEnabled`의 Release 경로를 활성화한다. 실제 사용자 데이터와 운영 서비스로 자동 시험하지 않는다.

2026-10-23 장비 조회에서는 iPhone 14가 paired/available로 나타났다. 장비 연결 상태 확인과 실기기 앱 검증은 별개이며, 사용자 기기의 기존 MORA 데이터로 테스트하지 않았다.
