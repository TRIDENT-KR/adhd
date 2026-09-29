import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 48) {
                    VStack(spacing: 16) {
                        Text("Mora")
                            .font(DesignSystem.Typography.displayLg)
                            .foregroundColor(DesignSystem.Colors.primary)
                            .tracking(-1.5)
                        Text(L.login.subtitle)
                            .font(DesignSystem.Typography.bodyMd)
                            .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                    }

                    if authManager.isProcessing {
                        ProgressView()
                            .tint(DesignSystem.Colors.primary)
                            .accessibilityLabel("Signing in")
                    } else {
                        SignInWithAppleButton { request in
                            authManager.prepareAppleSignInRequest(request)
                        } onCompletion: { result in
                            authManager.handleAppleSignInResult(result)
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 56)
                        .cornerRadius(28)
                        .padding(.horizontal, 48)
                    }

                    VStack(spacing: 16) {
                        Text(.init("\(L.login.tosPrefix)[\(L.login.tosLink)](https://trident-kr.github.io/waitwhat-site/terms/)\(L.login.tosSuffix)"))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(L.settings.privacyPolicy, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/privacy/")!)
                            .frame(minHeight: 44)
                    }
                    .font(DesignSystem.Typography.labelSm)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            }
        }
        .tint(DesignSystem.Colors.primary)
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView().environmentObject(AuthManager())
    }
}
