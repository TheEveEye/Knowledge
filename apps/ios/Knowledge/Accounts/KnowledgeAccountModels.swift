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

nonisolated enum KnowledgeAccountError: Error, LocalizedError {
    case unavailable, invalidCode, expiredCode, unauthorized, invalidResponse, connection, storage
    case invalidCredentials, emailNotVerified, passwordRequirements
    case rateLimited(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Account services are temporarily unavailable. Please try again later."
        case .invalidCredentials: "The email or password is incorrect. If your account used email codes, choose Set or reset password first."
        case .emailNotVerified: "Verify your email before signing in."
        case .passwordRequirements: "Choose a password between 15 and 128 characters."
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
