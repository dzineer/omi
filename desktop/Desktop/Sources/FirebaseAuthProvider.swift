import Foundation
@preconcurrency import FirebaseAuth

/// Auth provider that delegates to the Firebase Auth SDK.
/// This is the only file (besides the app entry point) that imports FirebaseAuth.
@MainActor
class FirebaseAuthProvider: AuthProvider {
    private var authStateHandle: AuthStateDidChangeListenerHandle?

    func configure() {
        // Nothing needed — FirebaseApp.configure() is called in VibeAiApp.swift before this
    }

    var currentUser: AuthUser? {
        guard let user = Auth.auth().currentUser else { return nil }
        return AuthUser(
            uid: user.uid,
            email: user.email,
            displayName: user.displayName,
            refreshToken: user.refreshToken
        )
    }

    func addStateDidChangeListener(_ callback: @escaping @Sendable (AuthUser?) -> Void) {
        authStateHandle = Auth.auth().addStateDidChangeListener { _, user in
            if let user = user {
                callback(AuthUser(
                    uid: user.uid,
                    email: user.email,
                    displayName: user.displayName,
                    refreshToken: user.refreshToken
                ))
            } else {
                callback(nil)
            }
        }
    }

    func signInWithCredential(providerID: String, idToken: String, rawNonce: String) async throws -> AuthUser {
        let firebaseProviderID: AuthProviderID
        switch providerID {
        case "apple":   firebaseProviderID = .apple
        case "google":  firebaseProviderID = .google
        default:
            NSLog("VIBE AI AUTH: Unknown provider ID '%@', defaulting to Apple", providerID)
            firebaseProviderID = .apple
        }

        let credential = OAuthProvider.credential(
            providerID: firebaseProviderID,
            idToken: idToken,
            rawNonce: rawNonce
        )
        let authResult = try await Auth.auth().signIn(with: credential)
        let user = authResult.user
        return AuthUser(
            uid: user.uid,
            email: user.email,
            displayName: user.displayName,
            refreshToken: user.refreshToken
        )
    }

    func signInWithCustomToken(_ token: String) async throws -> AuthUser {
        let authResult = try await Auth.auth().signIn(withCustomToken: token)
        let user = authResult.user
        return AuthUser(
            uid: user.uid,
            email: user.email,
            displayName: user.displayName,
            refreshToken: user.refreshToken
        )
    }

    func getIDTokenResult(forcingRefresh: Bool) async throws -> AuthTokenResult {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notSignedIn
        }
        let result = try await user.getIDTokenResult(forcingRefresh: forcingRefresh)
        return AuthTokenResult(token: result.token, expirationDate: result.expirationDate)
    }

    func updateDisplayName(_ name: String) async throws {
        guard let user = Auth.auth().currentUser else { return }
        let changeRequest = user.createProfileChangeRequest()
        changeRequest.displayName = name
        try await changeRequest.commitChanges()
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }
}
