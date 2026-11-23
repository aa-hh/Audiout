# Faithful port of NativeBackend+Bluetooth.swift applyCompanionAlignmentMeasurement (2141-2238),
# btStoredAlignmentOffsetMs (1820), BTSpeakerTiming.decision (641), endBTWizardLatencyPreview keep path (3057-3075),
# claimCompanionProbeRun trim suspension (2034) and btDelayMs (1804).
REPLACE_MS = 20.0  # AlignmentThresholds.replaceMs (exact value irrelevant: |150-150| = 0)
def snap(x): return round(x * 10) / 10

class Backend:
    def __init__(s, latency=None, trim=None):
        s.lat = {} if latency is None else {"bt": latency}
        s.trim = {} if trim is None else {"bt": trim}
        s.sink_trim = s.trim.get("bt", 0)
    def stored_offset(s, uid): return s.lat.get(uid, s.trim.get(uid))
    def delay_ms(s, uid):
        if uid not in s.lat and uid not in s.trim: return None
        return s.trim.get(uid, 0) + s.lat.get(uid, 0)
    def claim(s, uid):
        s.run_trim_at_start = s.trim.get(uid, 0); s.sink_trim = 0   # trim suspended
    def end_latency_preview_keep(s, uid, keep):
        v = max(0, round(keep)); s.lat[uid] = v; s.trim[uid] = 0; s.sink_trim = 0
    def end_latency_preview_nil(s, uid): pass  # pushes stored latency to the sink only
    def apply(s, uid, offset, fixed=False):
        applied = s.lat.get(uid, 0)
        lo, hi = -500.0, 2000.0
        corrected = snap(applied + offset)
        value = min(max(corrected, lo), hi)
        stored = s.stored_offset(uid)
        decision = "replace" if stored is None or abs(value - stored) >= REPLACE_MS else "keepStored"
        kept = value if decision == "replace" else applied
        if not fixed:
            s.end_latency_preview_keep(uid, kept)
        else:
            if decision == "replace":
                s.end_latency_preview_keep(uid, value)
            else:
                s.end_latency_preview_nil(uid)
                s.sink_trim = s.run_trim_at_start   # setBTWizardTrimPreview(run.trimAtSessionStartMs)
        return decision, max(0, kept) - applied
