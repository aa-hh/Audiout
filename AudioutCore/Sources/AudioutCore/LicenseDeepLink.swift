// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The purchase flow's return link, `audiout://register?key=<key>`.
///
/// Parsing lives here rather than in the app target's Apple Event handler
/// because a deep link is the one input a web page can hand the app
/// unprompted — it is a trust boundary, and the app target is invisible to the
/// test suite.
public enum LicenseDeepLink {

    /// The license key `url` carries, or `nil` for anything else. A missing,
    /// empty or unparseable key is rejected SILENTLY: the caller must never put
    /// an alert on the user's screen for a link they may not have meant to
    /// follow. Percent-encoding is undone by `URLComponents`, and surrounding
    /// whitespace is trimmed so a link wrapped by a mail client still lands.
    public static func parse(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "audiout",
              url.host?.lowercased() == "register",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let key = components.queryItems?.first(where: { $0.name == "key" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }
}
