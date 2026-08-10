// Is now-playing state reachable? Apple restricted MediaRemote around macOS
// 15.4 (entitlement-gated); this checks rather than assumes.
import Foundation

let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let handle = dlopen(path, RTLD_NOW) else {
    print("FAIL: MediaRemote will not dlopen — \(String(cString: dlerror()))"); exit(1)
}
print("dlopen ok")
for sym in ["MRMediaRemoteGetNowPlayingApplicationIsPlaying",
            "MRMediaRemoteGetNowPlayingInfo",
            "MRMediaRemoteRegisterForNowPlayingNotifications"] {
    print("  \(dlsym(handle, sym) != nil ? "present" : "MISSING") — \(sym)")
}

typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
guard let s = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else { exit(1) }
let isPlaying = unsafeBitCast(s, to: IsPlayingFn.self)
let sem = DispatchSemaphore(value: 0)
var answered = false
isPlaying(DispatchQueue.main) { playing in
    print("\nCALLBACK: isPlaying = \(playing)")
    answered = true; sem.signal()
}
DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if !answered { print("\nNO CALLBACK within 3s — gated/silent"); sem.signal() } }
_ = sem.wait(timeout: .now() + 4)
