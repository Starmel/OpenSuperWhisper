// OpenSuperWhisper media-remote helper.
//
// macOS 15.4+ only lets Apple *platform binaries* use the private MediaRemote
// framework; an unentitled process (our app) gets empty/false data back. So the
// media queries and commands must run inside `/usr/bin/perl`, which is such a
// platform binary. `osw-media-remote.pl` dlopens THIS dylib into perl's entitled
// process and calls one of the exported C symbols below.
//
// This dylib is bundled in the app but NEVER linked into it - perl loads it by
// absolute path. Each entry point is invoked by perl as an XSUB; the extra perl
// arguments are ignored.
//
//   osw_media_get   -> writes "true" or "false" (is anything playing) to stdout
//   osw_media_pause -> sends kMRPause  (discrete; a no-op if nothing is playing)
//   osw_media_play  -> sends kMRPlay
//
// Only two private MediaRemote symbols are used, both stable for years:
//   MRMediaRemoteGetNowPlayingApplicationIsPlaying(queue, block(Bool))
//   MRMediaRemoteSendCommand(MRCommand, userInfo) -> Bool

import Foundation

private let mediaRemotePath =
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"

// MRCommand values (stable private constants).
private let kMRPlay: Int32 = 0
private let kMRPause: Int32 = 1

private let mediaRemote = dlopen(mediaRemotePath, RTLD_NOW)

private func mediaRemoteSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    guard let mediaRemote else { return nil }
    return dlsym(mediaRemote, name)
}

private func writeStdout(_ string: String) {
    // FileHandle writes are unbuffered, so output survives the perl xsub return.
    FileHandle.standardOutput.write(Data(string.utf8))
}

/// Blocks (up to `timeout`) on MediaRemote's async "is playing" callback.
/// Returns false on any failure so callers fail safe.
private func isPlaying(timeout: TimeInterval = 2) -> Bool {
    typealias Fn = @convention(c) (
        DispatchQueue, @escaping @convention(block) (Bool) -> Void
    ) -> Void
    guard let symbol = mediaRemoteSymbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying")
    else { return false }
    let getIsPlaying = unsafeBitCast(symbol, to: Fn.self)

    let semaphore = DispatchSemaphore(value: 0)
    var playing = false
    getIsPlaying(DispatchQueue.global()) { value in
        playing = value
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeout)
    return playing
}

private func sendCommand(_ command: Int32) {
    typealias Fn = @convention(c) (Int32, UnsafeRawPointer?) -> Bool
    guard let symbol = mediaRemoteSymbol("MRMediaRemoteSendCommand") else { return }
    let send = unsafeBitCast(symbol, to: Fn.self)
    _ = send(command, nil)
    // One more MediaRemote round-trip so the command reaches the media daemon
    // before perl exits (mirrors the reference adapter's waitForCommandCompletion).
    _ = isPlaying(timeout: 2)
}

@_cdecl("osw_media_get")
public func osw_media_get() {
    writeStdout(isPlaying() ? "true" : "false")
}

@_cdecl("osw_media_pause")
public func osw_media_pause() {
    sendCommand(kMRPause)
}

@_cdecl("osw_media_play")
public func osw_media_play() {
    sendCommand(kMRPlay)
}
