import sys; from port import Backend
fixed = "--fixed" in sys.argv
b = Backend(latency=None, trim=150.0)
before = b.delay_ms("bt")
b.claim("bt")
decision, corrected_ms = b.apply("bt", 150.0, fixed=fixed)
after = b.delay_ms("bt")
print(f"decision={decision} correctedMs={corrected_ms} delay before={before} after={after} sinkTrim={b.sink_trim}")
assert decision == "keepStored" and corrected_ms == 0, "phone told 'number stood'"
assert after == before, f"FAIL: re-check that agreed moved the speaker {before} -> {after}"
print("PASS")
