# Mora 스토어 입력 초안

> **2026-09-30 결정 변경:** 성인 전용 출시·Gemini 유지. 아래9/29의 전 연령/AI 교체 계획은 폐기한다. 최신 미완료 항목은 [출시 잔여 점검](MORA_RELEASE_REMAINING_20260930.md)을 따른다. 성인 이용 조건의 앱·약관·스토어 반영은 아직 완료되지 않았다.

2026-09-29 · 앱 1.0 (4) 기준. **18세 제한 없는 출시 방향에 맞춰 AI 제공 방식을 전환하고, 어린이 보호 조건·공개 정책·Apple 설정·실기기 QA를 완료한다.** 아래는 복사 가능한 문구이며 ASC에 저장하거나 공개하지 않았다. 의료·치료 효과, 알람 전달 보장, 백업·동기화, 고정 할인율은 주장하지 않는다.

아래 Google Gemini 문구는 현재 구현의 설명이다. 대체 제공자 선정·전환 뒤 실제 처리 방식으로 바꾸기 전에는 제출하지 않는다.

## 공통 입력

| 필드 | 값 / 처리 |
|---|---|
| 기본 카테고리 | 생산성 / Productivity |
| Support URL | https://trident-kr.github.io/waitwhat-site/ — 웹 PR #1 게시 후 실제 200 확인 |
| Privacy Policy URL | https://trident-kr.github.io/waitwhat-site/privacy/ — 대상 연령·Google 조건 확정 후 게시 |
| Terms URL | https://trident-kr.github.io/waitwhat-site/terms/ |
| 고객 지원 | trident1398@gmail.com |
| 심사 연락처 | 담당자의 실제 성명·전화·이메일을 소유자가 입력 |
| 저작권 | 실제 권리자·법인명을 소유자가 확인하여 입력. 저장소 조직명이 법적 권리자라고 추정하지 않음 |
| 연령·국가 | 제품 결정 및 Google 지원 지역과 일치. 기존 13세 미만 제외 문구로 제출하지 않음 |
| 플랫폼 | iPhone, iOS 26.2 이상. 스크린샷·기능 설명은 검증한 실제 화면 기준 |

## 한국어

**앱 이름:** Mora: 할 일과 루틴

**부제:** 말로 정리하고 하나씩 실천해요

**키워드:** 할일,루틴,일정,음성,정리,리마인더,계획,체크리스트,습관

**설명:**

해야 할 일을 떠올렸을 때, Mora에 적거나 말해 보세요. 음성으로 만든 초안을 확인하고 AI로 일정과 할 일을 정리할 수 있어요.

일정과 루틴은 계정 없이 직접 추가하고 관리할 수 있어요. 기본 알림으로 다음 할 일을 확인하고, 완료한 항목을 하나씩 체크해 보세요. 일정은 기기에 저장되며 현재 버전에는 클라우드 백업과 기기 간 일정 동기화가 없어요.

AI 분석은 Apple 로그인과 별도의 데이터 전송 동의 후 사용할 수 있어요. 입력한 글 또는 수정한 음성 초안을 Supabase를 통해 Google Gemini에 전송해 분석해요. 무료 계정은 한국 표준시 기준 하루 3회 분석할 수 있어요.

Mora Pro는 일일 무료 분석 횟수 제한 해제, Pro 알람과 위젯 기능을 제공하는 자동 갱신 구독이에요. 과도한 연속 요청은 일시 제한될 수 있어요. 월간·연간 가격과 기간은 구매 화면에서 확인할 수 있으며 Apple 계정에서 관리·취소하고 앱에서 구매를 복원할 수 있어요. 앱이나 Mora 계정 삭제는 구독을 해지하지 않아요.

음성 인식, 알림, 알람은 기기의 권한과 설정에 따라 동작해요. 중요한 일정은 직접 확인해 주세요. Mora는 의료 진단이나 치료를 제공하지 않아요.

개인정보 처리방침: https://trident-kr.github.io/waitwhat-site/privacy/
이용약관: https://trident-kr.github.io/waitwhat-site/terms/

## English

**Name:** Mora: Tasks & Routines

**Subtitle:** Say it, plan it, take one step

**Keywords:** tasks,routine,planner,voice,reminders,checklist,schedule,habits,organizer

**Description:**

Capture a task when it comes to mind. Type it or create a voice draft, review the text, and let Mora’s optional AI analysis help organize it.

Add tasks and routines manually without an account. Use basic reminders and check off completed items. Schedules are stored on your device; this version does not offer cloud task backup or synchronization between devices.

AI analysis requires Sign in with Apple and separate data-sharing consent. Your text or edited speech draft is sent through Supabase to Google Gemini for analysis. Free accounts receive three analyses per Korea Standard Time day.

Mora Pro is an auto-renewing subscription with AI analysis beyond the free daily quota, Pro alarms and widgets. Excessive consecutive requests may be temporarily limited. Choose a monthly or annual plan; the purchase screen shows your current price and subscription period. Manage or cancel subscriptions in your Apple account and restore purchases in the app. Deleting the app or Mora account does not cancel a subscription.

Speech recognition, notifications and alarms depend on device permissions and settings. Verify important schedules yourself. Mora does not provide medical diagnosis or treatment.

Privacy policy: https://trident-kr.github.io/waitwhat-site/privacy/
Terms: https://trident-kr.github.io/waitwhat-site/terms/

## 日本語

**アプリ名:** Mora: タスクとルーティン

**サブタイトル:** 話して整理、一つずつ実行

**キーワード:** タスク,ルーティン,予定,音声,リマインダー,計画,チェックリスト,習慣,整理

**説明:**

やることを思いついたら、Moraに入力したり話しかけたりしてみましょう。音声で作った下書きを確認し、任意のAI分析でタスクや予定を整理できます。

タスクとルーティンは、アカウントなしで直接追加・管理できます。基本の通知を使い、完了した項目をチェックしましょう。予定は端末内に保存されます。現在のバージョンには予定のクラウドバックアップや端末間の同期はありません。

AI分析にはAppleでのサインインと、データ共有への個別の同意が必要です。入力した文章または編集した音声の下書きは、Supabaseを通じてGoogle Geminiへ送信されます。無料アカウントでは韓国標準時で1日3回分析できます。

Mora Proは、無料の1日あたりの分析回数制限を解除し、Proアラームとウィジェットを利用できる自動更新サブスクリプションです。過度の連続リクエストは一時的に制限される場合があります。月間または年間プランを選択でき、現在の価格と期間は購入画面に表示されます。Appleアカウントで管理・解約し、アプリから購入を復元できます。アプリやMoraアカウントを削除してもサブスクリプションは解約されません。

音声認識、通知、アラームは端末の許可と設定によって動作します。重要な予定はご自身でも確認してください。Moraは医療上の診断や治療を提供しません。

プライバシーポリシー: https://trident-kr.github.io/waitwhat-site/privacy/
利用規約: https://trident-kr.github.io/waitwhat-site/terms/

## スクリーンショット / 스크린샷 제작 기준

검증한 Release 후보의 실제 화면으로, ① 게스트 일정/루틴 ② 수동 추가 ③ 음성 초안 확인 ④ AI 분석 결과 ⑤ Pro 화면 순서를 권장한다. AI/Pro 화면에는 로그인·구독 필요 여부를 정확히 표시한다. 개인 일정·이메일·Apple 계정은 노출하지 않는다. StoreKit 테스트 설정이나 DEBUG demo를 실제 구매·동기화 완료의 증거로 쓰지 않는다. 요구되는 기기별 이미지 크기는 ASC 업로드 화면에서 확인한다.
