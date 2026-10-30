import AuthenticationServices
import SwiftUI

struct InternetAppleSignInSection: View {
    let viewModel: IntercomViewModel
    let workerURL: String
    @State private var authorization: InternetAccountAuthorization?
    @State private var message: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Section {
            Button("Set Up Internet Calling") {
                Task {
                    do {
                        let next = try authorization ?? viewModel.makeInternetAccountAuthorization()
                        authorization = next; message = nil
                        await next.prepare(url: workerURL)
                    } catch { message = "Internet sign-in is unavailable. Check your account and saved device information." }
                }
            }
            .disabled(workerURL.isEmpty || authorization?.isBusy == true)
            .accessibilityIdentifier("prepareInternetAppleSignIn")
            if let authorization {
                SignInWithAppleButton(.continue, onRequest: authorization.configure, onCompletion: authorization.complete)
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(maxWidth: 360).frame(height: 50)
                    .disabled(!authorization.isReady)
                    .accessibilityIdentifier("internetAppleSignInButton")
                if authorization.isBusy { ProgressView() }
                if let text = authorization.message { Text(text).font(.callout).accessibilityIdentifier("internetAppleSignInStatus") }
            }
            if let message { Text(message).font(.callout).accessibilityIdentifier("internetAppleSignInStatus") }
        } header: { Text("Connect with Apple") }
        footer: { Text("Use the same Apple Account as RideIntercom. Updating Internet access ends the current call. Nearby calling remains available if this service cannot be reached.") }
        .onChange(of: workerURL) { authorization?.cancel(); authorization = nil; message = nil }
        .task { await viewModel.retryInternetAccountRevocation() }
        .onDisappear { authorization?.cancel() }
    }
}
