// CompletionRegistry.install() is the seam that makes a second engine instance
// visible: the C completion hook reads one process-wide `shared`, so a second
// `install()` silently redirects every in-flight completion of the first engine
// (whose ops then only resolve by timeout). Nested under `SerializedEngineState`
// because it mutates that process-wide `shared`.

import Testing
@testable import AirPlayEngine

extension SerializedEngineState {

    @Suite struct CompletionRegistryTests {

        @Test func installReportsWhenItDisplacesAnotherLiveRegistry() {
            // Earlier tests enter headless mode without stopping their engine, so a
            // leaked registry is usually still installed here. Clear it first: the
            // assertion below is about displacing a LIVE peer, not about inheriting
            // someone else's leftover.
            CompletionRegistry.shared?.uninstall()
            #expect(CompletionRegistry.shared == nil)

            let a = CompletionRegistry()
            let b = CompletionRegistry()

            #expect(a.install() == true)
            #expect(b.install() == false, "a second install silently displaced the first engine's C hook")
            #expect(CompletionRegistry.shared === b)

            a.uninstall()
            #expect(CompletionRegistry.shared === b, "uninstall only clears shared when it is still self")

            b.uninstall()
            #expect(CompletionRegistry.shared == nil)

            #expect(b.install() == true, "a clean install after uninstall displaces nothing")
            b.uninstall()
        }
    }
}
