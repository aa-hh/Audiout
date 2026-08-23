// SPDX-License-Identifier: GPL-2.0-or-later
//
// PTPClockProbe.swift — thin Swift surface over the shim's
// `ptpd_daemon_probe()` (T4, PLAN-AIRPLAY-COEXISTENCE.md). `AudioutCore`
// depends on the `AirPlayEngine` product only, never `CAirPlayEngine`
// directly (package boundary — see this package's root AGENTS.md), so this
// one-function wrapper is what lets the app-side PTP-helper activation
// (`PTPHelperService.swift`) poll for clock readiness without reaching past
// that boundary.

import CAirPlayEngine

/// Connect-time readiness check for the shared PTP clock daemon. Stateless
/// and side-effect-free on the engine's own session state: unlike
/// `AirPlayEngine.start()`'s `ptpd_find_or_bind()`, this never adopts a
/// daemon or touches the engine's cached handle — see `ptpd_daemon_probe()`'s
/// doc comment (`shims/ptpd.c`) for why that separation matters. Safe to
/// call from any thread, repeatedly, while polling for the on-demand helper
/// to come up.
public enum PTPClockProbe {
    /// `true` if a shared airptpd is up and its heartbeat is fresh right now.
    public static func isReady() -> Bool {
        ptpd_daemon_probe() == 0
    }
}
