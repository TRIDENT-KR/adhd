import Foundation

extension Strings {
    var adultEligibility: AdultEligibility { AdultEligibility(s: self) }
    struct AdultEligibility {
        let s: Strings
        var title: String { s.t("For adults 18 and older", "만 18세 이상을 위한 앱", "18歳以上の方のためのアプリ") }
        var explanation: String { s.t("Mora is available only to adults aged 18 or older. Confirm your age before continuing. This is your own declaration, not verified proof of age. We do not ask for your birth date or an identity document.", "Mora는 만 18세 이상만 사용할 수 있어요. 계속하기 전에 연령을 직접 확인해 주세요. 본인의 진술이며 연령을 검증하는 절차가 아니에요. 생년월일이나 신분증을 요청하지 않아요.", "Moraは18歳以上の方のみご利用いただけます。続ける前に年齢を自己申告してください。これは年齢を証明・検証する手続きではありません。生年月日や身分証明書は求めません。") }
        var affirmative: String { s.t("I am 18 or older", "만 18세 이상이에요", "18歳以上です") }
        var under18: String { s.t("I am under 18", "만 18세 미만이에요", "18歳未満です") }
        var restrictedTitle: String { s.t("Mora is not available to you", "지금은 Mora를 사용할 수 없어요", "現在Moraをご利用いただけません") }
        var restrictedMessage: String { s.t("You indicated that you are under 18. This restriction stays on this device after restarting or changing accounts. You can still delete an existing account and manage Apple subscriptions. If your answer was a mistake, contact support; do not send your birth date or ID.", "만 18세 미만이라고 응답했어요. 앱을 다시 열거나 계정을 바꿔도 이 기기의 제한은 유지돼요. 기존 계정 삭제와 Apple 구독 관리는 계속할 수 있어요. 잘못 응답했다면 고객 지원에 문의해 주세요. 생년월일이나 신분증은 보내지 마세요.", "18歳未満と回答されました。再起動やアカウントの変更後も、このデバイスの制限は続きます。既存アカウントの削除とAppleのサブスクリプション管理は引き続き可能です。回答を間違えた場合はサポートにお問い合わせください。生年月日や身分証明書は送らないでください。") }
        var rejectConfirmation: String { s.t("Confirm your answer", "응답을 확인해 주세요", "回答を確認してください") }
        var rejectExplanation: String { s.t("Confirming that you are under 18 will restrict Mora on this device. There is no in-app switch to change this answer. Account deletion and Apple subscription management remain available.", "만 18세 미만으로 확인하면 이 기기에서 Mora 사용이 제한돼요. 앱 안에서 응답을 바꾸는 버튼은 제공하지 않아요. 계정 삭제와 Apple 구독 관리는 계속할 수 있어요.", "18歳未満と確定すると、このデバイスでMoraの利用が制限されます。アプリ内で回答を変更するボタンはありません。アカウント削除とAppleのサブスクリプション管理は引き続き利用できます。") }
        var confirmUnder18: String { s.t("Confirm under 18", "만 18세 미만으로 확인", "18歳未満と確定") }
        var management: String { s.t("Account, subscriptions and help", "계정·구독 관리 및 도움말", "アカウント・契約管理とヘルプ") }
        var managementSignIn: String { s.t("Sign in to manage an existing account", "기존 계정을 관리하려면 로그인", "既存アカウントを管理するためにログイン") }
        var managementExplanation: String { s.t("Signing in here does not remove the age restriction. New purchases and normal app use stay unavailable until eligible.", "여기서 로그인해도 연령 제한은 해제되지 않아요. 이용 자격이 확인되기 전에는 새 구매와 일반 기능을 사용할 수 없어요.", "ここでログインしても年齢制限は解除されません。利用条件を満たすまでは新規購入と通常の機能は利用できません。") }
        var acceptedStatus: String { s.t("Self-declared age 18+", "만 18세 이상으로 직접 응답함", "18歳以上と自己申告済み") }
        var unknownStatus: String { s.t("Age declaration required", "연령 직접 확인 필요", "年齢の自己申告が必要") }
        var settingsExplanation: String { s.t("Your declaration is saved separately for this account or local storage. AI and new purchases also require an online confirmation for the signed-in account.", "연령 응답은 계정 또는 기기 저장소별로 따로 저장돼요. AI와 새 구매는 로그인한 계정의 온라인 확인도 필요해요.", "自己申告はアカウントまたはデバイス内の保存先ごとに記録されます。AIと新規購入には、ログイン中のアカウントのオンライン確認も必要です。") }
        var reviewDeclaration: String { s.t("Review and confirm declaration", "연령 응답 확인 및 전송", "自己申告を確認・送信") }
        var serverRequired: String { s.t("Confirm that you are 18 or older in Settings before using AI or making a new purchase.", "AI 또는 새 구매를 사용하려면 설정에서 만 18세 이상 응답을 확인하고 전송해 주세요.", "AIや新規購入の前に、設定から18歳以上の自己申告を確認・送信してください。") }
        var serverUnavailable: String { s.t("Could not confirm eligibility online. Your local age declaration is saved. Reconnect and confirm it in Settings before using AI or making a new purchase.", "온라인으로 이용 자격을 확인하지 못했어요. 기기의 연령 응답은 저장됐어요. 연결 후 설정에서 다시 확인하고 전송하면 AI와 새 구매를 사용할 수 있어요.", "オンラインで利用条件を確認できませんでした。デバイスの自己申告は保存されています。再接続し、設定から確認・送信してからAIや新規購入をご利用ください。") }
        var accountChanged: String { s.t("The account changed. Confirm again for the current account.", "계정이 변경됐어요. 현재 계정에서 다시 확인해 주세요.", "アカウントが変更されました。現在のアカウントで再度確認してください。") }
        var support: String { s.t("Support and eligibility help", "고객 지원 및 이용 자격 도움말", "サポートと利用条件のヘルプ") }
        var restoreCompleted: String { s.t("Your existing purchase was restored. The age restriction still applies to using Mora.", "기존 구매를 복원했어요. Mora 사용에 대한 연령 제한은 유지돼요.", "既存の購入を復元しました。Moraの利用に関する年齢制限は引き続き適用されます。") }
        var deletionWithoutCount: String { s.t("This permanently deletes the signed-in Mora account and all its associated schedules. Separate local schedules remain. Apple subscriptions must be canceled separately.", "로그인한 Mora 계정과 해당 계정의 모든 일정이 영구 삭제돼요. 별도의 기기 일정은 유지되며 Apple 구독은 따로 해지해야 해요.", "ログイン中のMoraアカウントと関連する全予定を完全に削除します。別に保存されたデバイス内の予定は残り、Appleのサブスクリプションは別途解約が必要です。") }
        func error(_ error: AdultEligibilityError) -> String {
            switch error {
            case .required: return serverRequired
            case .restricted: return restrictedMessage
            case .unavailable: return serverUnavailable
            case .accountChanged: return accountChanged
            }
        }
    }
}
