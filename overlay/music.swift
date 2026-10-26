// The jukebox's music, with nothing to install: no ffmpeg, and no Minecraft.
//
// Where Minecraft is installed, its launcher's assets folder has the music. Where
// it is not, or a track is missing there, the track comes from Mojang's own asset
// servers, where the launcher gets it, the first time it plays, and is kept in
// the cache after. The game ships Ogg Vorbis, which macOS does not play: each
// track is decoded with stb_vorbis (public domain, in vorbis/) and written as AAC
// for AVAudioPlayer.

import AVFoundation
import Foundation

let musicCache = cacheDir.appendingPathComponent("music")

/// The asset index fetched from Mojang, once there is one: the objects by key.
func downloadedIndex() -> [String: [String: Any]]? {
    guard let data = try? Data(contentsOf: musicCache.appendingPathComponent("index.json")) else { return nil }
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["objects"] as? [String: [String: Any]]
}

var fetchingIndex = false
/// Fetches the newest release's asset index from Mojang, as the launcher does, into
/// the cache. `done` runs on the main queue, true when the index is there.
func fetchIndex(_ done: @escaping (Bool) -> Void) {
    guard !fetchingIndex else { return }
    fetchingIndex = true
    DispatchQueue.global().async {
        func json(_ address: String) -> [String: Any]? {
            guard let url = URL(string: address), let data = try? Data(contentsOf: url) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        var ok = false
        if let manifest = json("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"),
           let latest = (manifest["latest"] as? [String: Any])?["release"] as? String,
           let version = (manifest["versions"] as? [[String: Any]])?.first(where: { $0["id"] as? String == latest })?["url"] as? String,
           let address = (json(version)?["assetIndex"] as? [String: Any])?["url"] as? String,
           let url = URL(string: address), let data = try? Data(contentsOf: url) {
            try? FileManager.default.createDirectory(at: musicCache, withIntermediateDirectories: true)
            ok = (try? data.write(to: musicCache.appendingPathComponent("index.json"), options: .atomic)) != nil
        }
        DispatchQueue.main.async {
            fetchingIndex = false
            done(ok)
        }
    }
}

/// The track's file: there already, or fetched from Mojang into the cache. `done`
/// runs on the main queue with its path, or nil when it could not be had.
func fetchTrack(_ track: Track, _ done: @escaping (String?) -> Void) {
    if FileManager.default.fileExists(atPath: track.path) { done(track.path); return }
    guard let remote = track.url.flatMap(URL.init(string:)) else { done(nil); return }
    URLSession.shared.downloadTask(with: remote) { file, response, _ in
        var got: String? = nil
        if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
            let dest = URL(fileURLWithPath: track.path)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.moveItem(at: file, to: dest)) != nil { got = track.path }
        }
        DispatchQueue.main.async { done(got) }
    }.resume()
}

/// Decodes an Ogg Vorbis file and writes it to `dest` as AAC. False if either fails.
func decodeVorbis(_ path: String, to dest: URL) -> Bool {
    var error: Int32 = 0
    guard let vorbis = stb_vorbis_open_filename(path, &error, nil) else { return false }
    defer { stb_vorbis_close(vorbis) }
    let info = stb_vorbis_get_info(vorbis)
    let channels = Int(info.channels), rate = Double(info.sample_rate)
    guard channels > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) else { return false }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 192_000]
    try? FileManager.default.removeItem(at: dest)
    guard let file = try? AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192), let planes = buffer.floatChannelData else { return false }
    let outputs = UnsafeMutableRawPointer(mutating: planes).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)
    while true {
        let frames = stb_vorbis_get_samples_float(vorbis, Int32(channels), outputs, 8192)
        if frames <= 0 { break }
        buffer.frameLength = AVAudioFrameCount(frames)
        do { try file.write(from: buffer) } catch { return false }
    }
    return true
}
