import SwiftUI
import AuthenticationServices

struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        ZStack {
            // Warm paper background
            DesignSystem.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 48) {
                Spacer()

                // Minimalist Branding
                VStack(spacing: 16) {
                    Text("WaitWhat")
                        .font(DesignSystem.Typography.displayLg)
                        .foregroundColor(DesignSystem.Colors.primary)
                        .tracking(-1.5)

                    Text(L.login.subtitle)
                        .font(DesignSystem.Typography.bodyMd)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                }

                Spacer()

                // Sign in with Apple Button
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

                // ToS with clickable link (#22)
                HStack(spacing: 0) {
                    Text(L.login.tosPrefix)
                    Link(L.login.tosLink, destination: URL(string: "https://waitwhat.app/terms")!)
                        .underline()
                    Text(L.login.tosSuffix)
                }
                .font(DesignSystem.Typography.labelSm)
                .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.7))
                .padding(.bottom, 24)
            }
        }
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .environmentObject(AuthManager())
    }
}
