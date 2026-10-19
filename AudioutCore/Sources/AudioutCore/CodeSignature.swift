import Foundation
import Security

/// Reads of the RUNNING binary's own code signature, via the public
/// `SecCodeCopySelf` + `SecCodeCopyStaticCode` + `SecCodeCopySigningInformation`
/// chain (ordinary, App-Store-safe Security.framework calls). Every reader
/// returns `nil` on an unsigned build or any API error; callers treat that as
/// "unknown", never as a specific answer.
public enum CodeSignature {
    /// The `kSecCodeInfoUnique` cdhash — stable per signed binary, changes on
    /// every rebuild. What TCC pins a grant to.
    static func currentIdentity() -> String? {
        guard let unique = signingInformation()?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// The Apple Developer team that signed this binary (`kSecCodeInfoTeamIdentifier`).
    /// `nil` for an ad-hoc or unsigned build, which is what a build from a
    /// plain source checkout gets.
    public static func teamIdentifier() -> String? {
        signingInformation()?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func signingInformation() -> [String: Any]? {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &selfCode) == errSecSuccess,
              let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }
}
