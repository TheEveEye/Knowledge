import Foundation

nonisolated struct KnowledgeUser: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let email: String
    let emailVerified: Bool
    let image: String?

    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? email : name }
}

nonisolated struct KnowledgeCredentials: Codable, Sendable {
    let origin: String
    var token: String
    var user: KnowledgeUser
}

nonisolated enum KnowledgeAccountError: Error, LocalizedError, Equatable {
    case unavailable, invalidCode, expiredCode, unauthorized, invalidResponse, connection, storage
    case invalidCredentials, emailNotVerified, passwordRequirements
    case emailAlreadyRegistered, invalidEmail, invalidInput, registrationFailed, codeAttemptsExceeded
    case rateLimited(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Account services are temporarily unavailable. Please try again later."
        case .invalidCredentials: "The email or password is incorrect."
        case .emailAlreadyRegistered: "An account with this email address already exists. Log in or choose Forgot password? to reset your password."
        case .invalidEmail: "Enter a valid email address."
        case .invalidInput: "Check the information you entered and try again."
        case .registrationFailed: "Your account could not be created. Please try again."
        case .codeAttemptsExceeded: "Too many incorrect attempts. Request a new code."
        case .emailNotVerified: "Verify your email before signing in."
        case .passwordRequirements: "Choose a password between 10 and 128 characters."
        case .invalidCode: "That code could not be verified. Enter the newest code from your email."
        case .expiredCode: "Your code has expired. Request a new one."
        case .unauthorized: "Your Knowledge session has ended. Sign in again."
        case .invalidResponse: "Knowledge returned an incomplete response. Please try again."
        case .connection: "Knowledge could not connect to the server. Check your connection and try again."
        case .storage: "Your Knowledge session could not be saved or cleared securely. Please try again."
        case .rateLimited: "Please wait before trying again."
        }
    }
}
