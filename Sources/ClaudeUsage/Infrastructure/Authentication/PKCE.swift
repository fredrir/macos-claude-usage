import CryptoKit
import Foundation
import Security

/// PKCE (Proof Key for Code Exchange) utilities conforming to RFC 7636.
public enum PKCE: Sendable {
    /// Generates a high-entropy cryptographic random string using base64url encoding.
    public static func generateCodeVerifier(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// Computes the code challenge using SHA-256 as required by `code_challenge_method=S256`.
    public static func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    /// Generates a cryptographically random state parameter for CSRF mitigation.
    public static func generateState(byteCount: Int = 24) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    /// Encodes data into RFC 4648 base64url format without trailing `=` padding.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
