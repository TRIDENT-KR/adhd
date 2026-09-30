import SwiftUI

struct AdultEligibilityView: View {
    let scopeID: UUID
    @ObservedObject private var eligibility = AdultEligibilityManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showUnder18Confirmation = false
    @State private var showManagement = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.primary)
                    .accessibilityHidden(true)
                Text(isRestricted ? L.adultEligibility.restrictedTitle : L.adultEligibility.title)
                    .font(DesignSystem.Typography.titleSm)
                Text(isRestricted ? L.adultEligibility.restrictedMessage : L.adultEligibility.explanation)
                    .font(DesignSystem.Typography.bodyMd)
                    .fixedSize(horizontal: false, vertical: true)
                if !isRestricted {
                    Button {
                        Task { @MainActor in
                            await eligibility.affirmAdult(for: scopeID)
                            if eligibility.activeScopeID == scopeID,
                               eligibility.allowsLocalUse(for: scopeID), eligibility.lastError == nil { dismiss() }
                        }
                    } label: {
                        Text(L.adultEligibility.affirmative)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(.white)
                            .background(LinearGradient(
                                colors: [DesignSystem.Colors.primary, DesignSystem.Colors.primary.opacity(0.78)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ), in: Capsule())
                    }
                    .disabled(eligibility.isSubmitting || eligibility.activeScopeID != scopeID)
                    Button(L.adultEligibility.under18) { showUnder18Confirmation = true }
                        .frame(minHeight: 44)
                        .disabled(eligibility.isSubmitting || eligibility.activeScopeID != scopeID)
                }
                if let error = eligibility.lastError {
                    Text(L.adultEligibility.error(error)).font(.footnote).foregroundStyle(.red)
                }
                Button(L.adultEligibility.management) { showManagement = true }
                    .frame(minHeight: 44)
            }
            .padding(32)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DesignSystem.Colors.background.ignoresSafeArea())
        .tint(DesignSystem.Colors.primary)
        .alert(L.adultEligibility.rejectConfirmation, isPresented: $showUnder18Confirmation) {
            Button(L.settings.cancel, role: .cancel) {}
            Button(L.adultEligibility.confirmUnder18, role: .destructive) {
                eligibility.recordUnder18(for: scopeID)
            }
        } message: { Text(L.adultEligibility.rejectExplanation) }
        .sheet(isPresented: $showManagement) { RestrictedAccountManagementView() }
    }

    private var isRestricted: Bool { eligibility.status(for: scopeID) == .restricted }
}

private struct RestrictedAccountManagementView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false
    @State private var showDeletion = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L.adultEligibility.managementExplanation).font(.footnote)
                    if authManager.accessState.accountUserID != nil {
                        Text(authManager.userEmail ?? L.authRelease.accountTitle)
                        Button(L.settings.deleteAccount, role: .destructive) { showDeletion = true }
                        Button {
                            guard let userID = authManager.accessState.accountUserID else { return }
                            restoreMessage = nil
                            Task { @MainActor in
                                let restored = await subscriptionManager.restorePurchasesForAccountManagement(userID: userID)
                                guard authManager.accessState.accountUserID == userID else { return }
                                restoreMessage = restored
                                    ? L.adultEligibility.restoreCompleted
                                    : (subscriptionManager.purchaseError ?? subscriptionManager.purchaseNotice)
                            }
                        } label: {
                            if subscriptionManager.isLoading { ProgressView() }
                            else { Text(L.paywall.restore) }
                        }
                        .disabled(subscriptionManager.isLoading || !authManager.canUseServerFeatures)
                        if !authManager.canUseServerFeatures {
                            Text(L.paywall.connectionRequired).font(.footnote)
                        }
                        if let restoreMessage { Text(restoreMessage).font(.footnote) }
                    } else {
                        Button(L.adultEligibility.managementSignIn) { showLogin = true }
                    }
                    Link(L.paywall.manageSubscription, destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    Text(L.settings.deletionSubscriptionNotice).font(.footnote)
                }
                .listRowSeparator(.hidden)
                Section {
                    Link(L.settings.privacyPolicy, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/privacy/")!)
                    Link(L.settings.termsOfService, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/terms/")!)
                    Link(L.adultEligibility.support, destination: URL(string: "https://trident-kr.github.io/waitwhat-site/")!)
                }
                .listRowSeparator(.hidden)
            }
            .navigationTitle(L.adultEligibility.management)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.settings.done) { dismiss() } } }
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        .sheet(isPresented: $showDeletion) { AccountDeletionFlowView(showsExactTaskCount: false) }
        .onChange(of: authManager.accessState.accountUserID) { _, _ in restoreMessage = nil }
    }
}
