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
                    
                    Text("Your AI thoughts companion.")
                        .font(DesignSystem.Typography.bodyMd)
                        .foregroundColor(DesignSystem.Colors.onSurfaceVariant)
                }
                
                Spacer()
                
                // Sign in with Apple Button
                if authManager.isProcessing {
                    ProgressView()
                        .tint(DesignSystem.Colors.primary)
                } else {
                    SignInWithAppleButton { request in
                        authManager.prepareAppleSignInRequest(request)
                    } onCompletion: { result in
                        authManager.handleAppleSignInResult(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 56)
                    .cornerRadius(28) // Rounded pill shape to match design system
                    .padding(.horizontal, 48)
                }
                
                Text("By signing in, you agree to our Terms of Service.")
                    .font(DesignSystem.Typography.labelSm)
                    .foregroundColor(DesignSystem.Colors.onSurfaceVariant.opacity(0.6))
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
