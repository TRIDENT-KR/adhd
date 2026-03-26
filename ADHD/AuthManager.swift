import Foundation
import Combine
import Supabase
import AuthenticationServices
import CryptoKit

class AuthManager: NSObject, ObservableObject {
    @Published var session: Session?
    @Published var isProcessing = false

    /// Settings에서 사용할 이메일 (Auth 모듈 import 없이 접근)
    var userEmail: String? {
        session?.user.email
    }
    
    private var currentNonce: String?
    

    
    override init() {
        super.init()
        Task {
            await checkSession()
        }
    }
    
    @MainActor
    func checkSession() async {
        do {
            self.session = try await supabase.auth.session
        } catch {
            self.session = nil
        }
    }
    
    func signOut() async {
        do {
            try await supabase.auth.signOut()
            await MainActor.run {
                self.session = nil
            }
        } catch {
            print("❌ Sign out error: \(error)")
        }
    }

    /// 계정 영구 삭제 (App Store 심사 필수 요구사항)
    func deleteAccount() async throws {
        // Supabase Edge Function 또는 Admin API로 사용자 삭제
        // 현재는 signOut 후 세션 제거로 처리 (서버측 삭제는 Edge Function 추가 필요)
        try await supabase.auth.signOut()
        await MainActor.run {
            self.session = nil
        }
    }
    
    // MARK: - Apple Sign In (SwiftUI Support)
    
    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }
    
    func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let idTokenData = appleIDCredential.identityToken,
                  let idToken = String(data: idTokenData, encoding: .utf8),
                  let nonce = currentNonce else {
                print("❌ Apple Sign In failed: Missing credentials or nonce")
                return
            }
            
            Task {
                do {
                    await MainActor.run { self.isProcessing = true }
                    let session = try await supabase.auth.signInWithIdToken(
                        credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
                    )
                    await MainActor.run {
                        self.session = session
                        self.isProcessing = false
                    }
                    print("✅ Apple Sign In success!")
                } catch {
                    print("❌ Supabase Auth error: \(error)")
                    await MainActor.run { self.isProcessing = false }
                }
            }
        case .failure(let error):
            print("❌ Apple Sign In error: \(error.localizedDescription)")
        }
    }
    
    // Legacy support for non-SwiftUI cases if needed
    func startAppleSignIn() {
        let nonce = randomNonceString()
        currentNonce = nonce
        
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
        
        let authorizationController = ASAuthorizationController(authorizationRequests: [request])
        authorizationController.delegate = self
        authorizationController.presentationContextProvider = self
        authorizationController.performRequests()
    }
    
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = randomBytes.map { charset[Int($0) % charset.count] }
        return String(nonce)
    }
    
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap { String(format: "%02x", $0) }.joined()
        return hashString
    }
}

extension AuthManager: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let idTokenData = appleIDCredential.identityToken,
              let idToken = String(data: idTokenData, encoding: .utf8),
              let nonce = currentNonce else {
            print("❌ Apple Sign In failed: Missing credentials")
            return
        }
        
        Task {
            do {
                await MainActor.run { self.isProcessing = true }
                let session = try await supabase.auth.signInWithIdToken(
                    credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
                )
                await MainActor.run {
                    self.session = session
                    self.isProcessing = false
                }
                print("✅ Apple Sign In success!")
            } catch {
                print("❌ Supabase Auth error: \(error)")
                await MainActor.run { self.isProcessing = false }
            }
        }
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        print("❌ Apple Sign In error: \(error.localizedDescription)")
    }
}

extension AuthManager: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first!
        return scene.windows.first { $0.isKeyWindow } ?? UIWindow(windowScene: scene)
    }
}
