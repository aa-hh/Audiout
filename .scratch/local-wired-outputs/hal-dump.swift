// Ticket 01 device dump. Run: swift .scratch/local-wired-outputs/hal-dump.swift
import CoreAudio
import Foundation

func get<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ zero: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = zero
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
}

func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    (get(id, sel, kAudioObjectPropertyScopeGlobal, nil as Unmanaged<CFString>?) ?? nil)?
        .takeRetainedValue() as String? ?? "?"
}

func array(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> [UInt32] {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [UInt32](repeating: 0, count: Int(size) / 4)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &out) == noErr ? out : []
}

func fourCC(_ v: UInt32) -> String {
    let s = String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)"
    return "'\(s)'"
}

func sourceName(_ id: AudioObjectID, _ src: UInt32) -> String {
    var src = src
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
                                          mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    let status = withUnsafeMutablePointer(to: &src) { srcPtr in
        withUnsafeMutablePointer(to: &name) { namePtr in
            var t = AudioValueTranslation(mInputData: srcPtr, mInputDataSize: 4, mOutputData: namePtr,
                                          mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
            return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        }
    }
    guard status == noErr else { return fourCC(src) }
    return name?.takeRetainedValue() as String? ?? fourCC(src)
}

func settable(_ id: AudioObjectID, element: UInt32) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                          mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    var ok: DarwinBoolean = false
    return AudioObjectHasProperty(id, &addr) && AudioObjectIsPropertySettable(id, &addr, &ok) == noErr && ok.boolValue
}

let out = kAudioObjectPropertyScopeOutput
let system = AudioObjectID(kAudioObjectSystemObject)
let defaultOut = get(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))

for id in array(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal) {
    let streams = array(id, kAudioDevicePropertyStreams, out)
    guard !streams.isEmpty else { continue }
    let rate = get(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0
    let lat = get(id, kAudioDevicePropertyLatency, out, UInt32(0)) ?? 0
    let safety = get(id, kAudioDevicePropertySafetyOffset, out, UInt32(0)) ?? 0
    let streamLat = streams.map { get($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0 }
    let total = lat + safety + (streamLat.first ?? 0)
    let ms = rate > 0 ? String(format: "%.1f", Double(total) / rate * 1000) : "?"
    let transport = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
    let current = get(id, kAudioDevicePropertyDataSource, out, UInt32(0))
    let sources = array(id, kAudioDevicePropertyDataSources, out).map { sourceName(id, $0) }

    print("""
    \(string(id, kAudioObjectPropertyName))\(id == defaultOut ? "   <- DEFAULT OUTPUT" : "")
      id=\(id)  uid=\(string(id, kAudioDevicePropertyDeviceUID))
      transport=\(fourCC(transport))  outputStreams=\(streams.count)  rate=\(rate)
      latency=\(lat) safety=\(safety) streamLatency=\(streamLat)  total=\(total) frames = \(ms) ms
      settableVolume main=\(settable(id, element: 0)) ch1=\(settable(id, element: 1))
      dataSource=\(current.map { sourceName(id, $0) } ?? "none")  allSources=\(sources)

    """)
}
