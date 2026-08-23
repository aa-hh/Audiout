// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Whether this Mac physically has a Touch Bar.
///
/// All that survives of a much larger type that used to borrow the user's Touch
/// Bar settings — presentation mode and Control Strip layout — so our own bar
/// would render. A live spike proved none of that was necessary: a full-width
/// `presentSystemModalTouchBar` presents with the settings untouched. The
/// borrowing was not merely redundant, it was harmful: those settings outlive
/// the process, so any exit that skipped the restore left the user with a Touch
/// Bar showing nothing but the emoji key and no way to know what to undo (hit
/// live 2026-08-08). Writing nothing makes that failure impossible rather than
/// recoverable.
public enum TouchBarHardware {

    public static var isPresent: Bool {
        guard let model = hardwareModel() else { return false }
        return touchBarModels.contains(model)
    }

    /// Every Touch Bar Mac that can run macOS 14, our deployment target.
    ///
    /// razor: a literal set, not a private API. The list is CLOSED and can never
    /// need another entry — the Touch Bar was discontinued after the 13" M2
    /// (2022), and Sonoma dropped every model older than 2018.
    private static let touchBarModels: Set<String> = [
        "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3", "MacBookPro15,4",  // 2018–2019
        "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4",  // 2019–2020
        "MacBookPro17,1",                                                        // 13" M1 2020
        "Mac14,7",                                                               // 13" M2 2022
    ]

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
