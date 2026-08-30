// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import AudioutCore

/// `LicenseDeepLink` (`Sources/AudioutCore/LicenseDeepLink.swift`) — what the
/// purchase flow's `audiout://register?key=…` link is allowed to mean.
///
/// This is a trust boundary: any web page can hand the app one of these
/// unprompted, so everything that is not a real key must come back `nil` — and
/// silently.
@Suite struct LicenseDeepLinkTests {

    private static let key = "AUDT-AAAAA-BBBBB-CCCCC-DDDDD"

    private func parse(_ text: String) -> String? {
        guard let url = URL(string: text) else { return nil }
        return LicenseDeepLink.parse(url)
    }

    @Test func theRegisterLinkYieldsItsKey() {
        #expect(parse("audiout://register?key=\(Self.key)") == Self.key)
    }

    /// A key that travelled through a mail client or a redirect arrives
    /// percent-encoded; `URLComponents` decodes it, and the surrounding
    /// whitespace is trimmed rather than saved into the key.
    @Test func aPercentEncodedKeyIsDecodedAndTrimmed() {
        #expect(parse("audiout://register?key=%20\(Self.key)%20") == Self.key)
        #expect(parse("audiout://register?key=AUDT%2DAAAAA") == "AUDT-AAAAA")
    }

    /// An empty (or whitespace-only) key is nothing to register.
    @Test func anEmptyKeyIsRefused() {
        #expect(parse("audiout://register?key=") == nil)
        #expect(parse("audiout://register?key=%20%20") == nil)
        #expect(parse("audiout://register") == nil, "no key parameter at all")
        #expect(parse("audiout://register?other=\(Self.key)") == nil)
    }

    /// Only `audiout://register` registers. Another host, another scheme or an
    /// extra path segment is somebody else's link.
    @Test func onlyTheRegisterHostOnTheAudioutSchemeCounts() {
        #expect(parse("audiout://buy?key=\(Self.key)") == nil)
        #expect(parse("https://register?key=\(Self.key)") == nil)
        #expect(parse("audiout://register/extra?key=\(Self.key)") == Self.key,
                "a trailing path is ignored — the host still says register")
    }

    /// Scheme and host are matched case-insensitively: LaunchServices and mail
    /// clients both rewrite case, and a link is not malformed for that.
    @Test func schemeAndHostAreCaseInsensitive() {
        #expect(parse("AUDIOUT://REGISTER?key=\(Self.key)") == Self.key)
    }

    /// Garbage never reaches the license surface.
    @Test func garbageIsRefused() {
        #expect(parse("not-a-url") == nil)
        #expect(parse("audiout://") == nil)
        #expect(parse("") == nil)
    }
}
