import Foundation

extension Strings {
    var authRelease: AuthRelease { AuthRelease(s: self) }

    struct AuthRelease {
        let s: Strings
        var settingsTitle: String { s.t("Settings", "설정", "設定") }
        var accountTitle: String { s.t("Mora account", "Mora 계정", "Moraアカウント") }
        var guestTitle: String { s.t("On this device · No account", "이 기기에서 사용 · 계정 없음", "このデバイスで使用 · アカウントなし") }
        /// 세션이 만료된 기존 Apple 로그인 사용자만 보는 설정 행입니다.
        var signIn: String { s.t("Sign in again", "다시 로그인하기", "もう一度ログイン") }
        var signingIn: String { s.t("Signing in", "로그인 중", "ログイン中") }
        var signInFailed: String { s.t("Sign-in failed. Check your connection and try again. You can continue using local schedules.", "로그인하지 못했어요. 연결 상태를 확인하고 다시 시도해 주세요. 기기에 저장된 일정은 계속 사용할 수 있어요.", "ログインできませんでした。接続を確認して再試行してください。デバイス内の予定は引き続き使えます。") }
        var continueLocally: String { s.t("Continue without signing in", "로그인 없이 계속", "ログインせずに続ける") }
        var guestPreserved: String { s.t("Schedules made without an account stay on this device, separate from account schedules. While you're signed in, their reminders don't ring. After signing in you can bring them into your account, or sign out to use them again.", "로그인 없이 만든 일정은 이 기기에 계정 일정과 별도로 보관돼요. 로그인해 있는 동안에는 이 일정의 알림이 울리지 않아요. 로그인한 뒤 계정으로 가져오거나, 로그아웃해 다시 사용할 수 있어요.", "ログインせずに作った予定は、このデバイスにアカウントの予定と分けて保存されます。ログイン中はこれらの予定の通知は届きません。ログイン後にアカウントへ取り込むか、ログアウトして再び使えます。") }
        var importGuestTitle: String { s.t("Bring over your local schedules?", "기기 일정을 가져올까요?", "デバイス内の予定を取り込みますか？") }
        func importGuestMessage(_ count: Int) -> String { s.t("You have \(count) schedule(s) made without an account. Bring them into this account so their reminders ring again. The originals stay on this device, and you can also do this later in Settings.", "로그인 없이 만든 일정 \(count)개가 이 기기에 있어요. 이 계정으로 가져오면 알림도 다시 울려요. 원본은 기기에 그대로 남고, 나중에 설정에서도 할 수 있어요.", "ログインせずに作った予定が\(count)件あります。このアカウントに取り込むと通知も再び届きます。元の予定はデバイスに残り、あとから設定でも取り込めます。") }
        var importGuestAction: String { s.t("Bring Over", "가져오기", "取り込む") }
        var importGuestLater: String { s.t("Not Now", "나중에 할게요", "あとで") }
        var sessionExpired: String { s.t("Your account session ended. These are your separate local schedules. Sign in again to see your account schedules.", "계정 세션이 만료됐어요. 지금은 별도로 보관된 기기 일정을 표시해요. 계정 일정을 보려면 다시 로그인해 주세요.", "アカウントのセッションが終了しました。現在は別に保存されたデバイス内の予定を表示しています。アカウントの予定を見るには再度ログインしてください。") }
        var copyGuestTasks: String { s.t("Copy local schedules to this account", "기기 일정을 이 계정으로 복사", "デバイス内の予定をこのアカウントにコピー") }
        func copyGuestExplanation(account: String) -> String { s.t("Copy schedules made without an account into \(account)? Existing account schedules will be kept. Original local schedules stay on this device. Previously copied schedules are skipped.", "로그인 없이 만든 일정을 \(account)에 복사할까요? 기존 계정 일정은 유지돼요. 원본 기기 일정도 남으며, 이미 복사한 일정은 건너뛰어요.", "ログインせずに作った予定を\(account)にコピーしますか？既存のアカウントの予定とデバイス内の原本は残ります。コピー済みの予定はスキップします。") }
        func copiedGuestTasks(_ count: Int) -> String { s.t("Copied \(count) schedules. The original local schedules are still on this device.", "일정 \(count)개를 복사했어요. 원본 기기 일정도 그대로 보관돼요.", "\(count)件の予定をコピーしました。デバイス内の原本はそのまま残っています。") }
        var copyGuestFailed: String { s.t("Could not copy the schedules. Your local schedules have been kept. Try again from the account you want to use.", "일정을 복사하지 못했어요. 원본 기기 일정은 보존돼요. 원하는 계정에서 다시 시도해 주세요.", "予定をコピーできませんでした。デバイス内の原本は保存されています。使用するアカウントから再試行してください。") }
        var logOutHint: String { s.t("Sign out and return to separate local schedules", "로그아웃하고 별도 기기 일정으로 돌아가요", "ログアウトして別のデバイス内の予定に戻ります") }
        var deleteAccountHint: String { s.t("Review account deletion and confirm with Apple", "계정 삭제 안내를 확인하고 Apple로 인증해요", "アカウント削除の内容を確認し、Appleで認証します") }
        var clearCompletedHint: String { s.t("Review completed schedules before deleting", "완료한 일정을 확인한 뒤 삭제해요", "完了した予定を確認してから削除します") }
        var clearAllHint: String { s.t("Review all schedules in this storage before deleting", "현재 저장소의 전체 일정을 확인한 뒤 삭제해요", "現在の保存先の全予定を確認してから削除します") }
        var deleteAnonymousAccountHint: String { s.t("Review what deleting the server record removes", "서버 기록을 지우면 무엇이 사라지는지 확인해요", "サーバー記録の削除内容を確認します") }
        var anonymousDeletionCompleteMessage: String { s.t("Mora's server record for this device has been deleted. Your schedules on this device are still here. App Store subscriptions must be canceled separately in Apple subscription settings.", "이 기기의 Mora 서버 기록을 삭제했어요. 이 기기의 일정은 그대로 있어요. App Store 구독은 Apple 구독 설정에서 따로 해지해야 해요.", "この端末のMoraサーバー記録を削除しました。この端末の予定はそのまま残っています。App Storeのサブスクリプションは、Appleのサブスクリプション設定で別途解約してください。") }
        var anonymousDeletionPendingMessage: String { s.t("Deleting the server record. Your schedules on this device stay.", "서버 기록을 지우고 있어요. 이 기기의 일정은 그대로 남아요.", "サーバーの記録を削除しています。この端末の予定はそのまま残ります。") }
        var retryDeletion: String { s.t("Try deletion again", "삭제 다시 시도", "削除をもう一度試す") }
        var deletionCompleteTitle: String { s.t("Account deleted", "계정 삭제 완료", "アカウントを削除しました") }
        var deletionCompleteMessage: String { s.t("Your Mora account and its schedules on this device have been deleted. Any separate local schedules remain. App Store subscriptions must be canceled separately in Apple subscription settings.", "Mora 계정과 이 기기의 해당 계정 일정이 삭제됐어요. 별도의 기기 일정은 유지돼요. App Store 구독은 Apple 구독 설정에서 따로 해지해야 해요.", "Moraアカウントとこのデバイス上のアカウントの予定を削除しました。別に保存されたデバイス内の予定は残ります。App StoreのサブスクリプションはAppleの設定で別途解約してください。") }
        var deletionDelay: String { s.t("Allow a few minutes for deletion. If Apple or the network is unavailable, the request stays pending. Reopen Mora to resume and reauthenticate if asked. If it is still pending after 24 hours, contact support with the request ID. A confirmation appears when deletion finishes.", "삭제에는 몇 분이 걸릴 수 있어요. Apple 또는 네트워크에 연결할 수 없으면 대기 상태로 남아요. Mora를 다시 열어 계속하고, 요청이 나오면 재인증해 주세요. 24시간 후에도 대기 중이면 요청 ID와 함께 고객 지원에 문의해 주세요. 완료되면 확인 안내가 표시돼요.", "削除には数分かかる場合があります。Appleやネットワークに接続できない場合は保留になります。Moraを開き直して再開し、求められた場合は再認証してください。24時間経っても保留の場合は、リクエストIDを添えてサポートにお問い合わせください。完了後に確認が表示されます。") }
        var deletionFinishing: String { s.t("Removing account data from this device…", "이 기기의 계정 데이터를 정리하고 있어요…", "このデバイスのアカウントデータを削除中…") }
        var requestID: String { s.t("Request ID", "요청 ID", "リクエストID") }
        var onlineRequired: String { s.t("Connect to the internet and try again.", "인터넷에 연결한 뒤 다시 시도해 주세요.", "インターネットに接続して再試行してください。") }
        var appleCredentialMissing: String { s.t("Apple authentication did not finish. Try again to continue deletion.", "Apple 재인증이 완료되지 않았어요. 삭제를 계속하려면 다시 시도해 주세요.", "Appleの認証が完了しませんでした。削除を続けるには再試行してください。") }
        var appleAccountMismatch: String { s.t("Use the same Apple account as your current Mora account.", "현재 Mora 계정과 같은 Apple 계정으로 인증해 주세요.", "現在のMoraアカウントと同じAppleアカウントを使用してください。") }
        var appleReauthenticationRequired: String { s.t("Authenticate with Apple again to continue deletion.", "삭제를 계속하려면 Apple로 다시 인증해 주세요.", "削除を続けるにはAppleで再認証してください。") }
        var deletionUnavailable: String { s.t("Could not confirm deletion status. Try again or contact support with the request ID.", "삭제 상태를 확인하지 못했어요. 다시 시도하거나 요청 ID와 함께 고객 지원에 문의해 주세요.", "削除の状況を確認できませんでした。再試行するか、リクエストIDを添えてサポートにお問い合わせください。") }
        var openSourceNotices: String { s.t("Open source notices", "오픈 소스 고지", "オープンソースのライセンス") }
        var noticesUnavailable: String { s.t("Notices are unavailable. Please contact support.", "고지를 불러오지 못했어요. 고객 지원에 문의해 주세요.", "ライセンスを読み込めませんでした。サポートにお問い合わせください。") }
    }
}
