import AVFoundation
import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Media playback (2.0.0 rc4, plan 5.2, D22): video and audio stream from
/// the vault with no temp file and no new dependency. AVPlayer reads a
/// `vaultpony-media://` URL whose bytes come from `VaultMediaLoader`, which
/// answers each request through `Vault.readAt` in chunks. The URL carries a
/// random id, never the file's name.
///
/// Nothing reaches Now Playing: the player controller is told not to update
/// it and VaultPony never sets `MPNowPlayingInfoCenter` or remote commands.
/// Every player stops at lock (SessionRegistry.lock).
enum MediaPlayback {
    @MainActor private static let players = NSHashTable<VaultMediaPlayer>.weakObjects()
    /// What AVFoundation on this device can play.
    private static let playableTypes: [UTType] = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }

    /// Video and audio AVFoundation can play, by extension.
    static func isPlayable(_ name: String) -> Bool {
        contentType(for: name) != nil
    }

    /// The type to report to AVFoundation, or nil if it can't play the file.
    static func contentType(for name: String) -> UTType? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              type.conforms(to: .audiovisualContent)
        else { return nil }
        return playableTypes.contains { type.conforms(to: $0) } ? type : nil
    }

    @MainActor
    static func register(_ player: VaultMediaPlayer) {
        players.add(player)
    }

    /// At lock: every player stops and lets go of the vault.
    @MainActor
    static func stopAll() {
        for player in players.allObjects {
            player.stop()
        }
        players.removeAllObjects()
    }
}

/// One file's player and the loader feeding it.
@MainActor
final class VaultMediaPlayer {
    let player: AVPlayer
    private let loader: VaultMediaLoader

    init?(session: VaultSession, path: String, name: String, size: UInt64) {
        guard let type = MediaPlayback.contentType(for: name),
              let url = URL(string: "\(VaultMediaLoader.scheme)://media/\(UUID().uuidString)")
        else { return nil }
        loader = VaultMediaLoader(session: session, path: path, size: size, contentType: type.identifier)
        let asset = AVURLAsset(url: url)
        // The resource loader keeps its delegate weakly; this object keeps it.
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        // Plays with the ring switch on silent, like other video apps.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        MediaPlayback.register(self)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        loader.stop()
    }
}

/// Serves AVFoundation's requests for a vault file. Content information
/// comes from the extension and the file size; data comes from
/// `Vault.readAt` (gated against the File Provider extension like every
/// other call), only the range asked for, in chunks.
final class VaultMediaLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "vaultpony-media"
    private static let chunkBytes: UInt64 = 512 << 10

    /// The delegate queue. `tasks` and `stopped` are only touched on it.
    let queue = DispatchQueue(label: "dev.norsehorse.vaultpony.media")
    private let session: VaultSession
    private let path: String
    private let size: UInt64
    private let contentType: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var stopped = false

    init(session: VaultSession, path: String, size: UInt64, contentType: String) {
        self.session = session
        self.path = path
        self.size = size
        self.contentType = contentType
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped, loadingRequest.request.url?.scheme == Self.scheme else { return false }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(clamping: size)
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = UInt64(max(dataRequest.requestedOffset, 0))
        let end: UInt64
        if dataRequest.requestsAllDataToEndOfResource {
            end = size
        } else {
            end = min(size, start &+ UInt64(max(dataRequest.requestedLength, 0)))
        }
        let key = ObjectIdentifier(loadingRequest)
        tasks[key] = Task { [weak self] in
            await self?.serve(loadingRequest, dataRequest, from: start, to: end, key: key)
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    /// At lock or when the player closes: cancel every request in flight.
    func stop() {
        queue.sync {
            stopped = true
            for task in tasks.values {
                task.cancel()
            }
            tasks.removeAll()
        }
    }

    private func serve(_ loadingRequest: AVAssetResourceLoadingRequest, _ dataRequest: AVAssetResourceLoadingDataRequest, from start: UInt64, to end: UInt64, key: ObjectIdentifier) async {
        var offset = start
        var failure: Error?
        while offset < end {
            // A cancelled request was dropped by AVFoundation (or by stop());
            // it expects no answer.
            if Task.isCancelled { return }
            let length = UInt32(min(Self.chunkBytes, end - offset))
            let chunk: Data
            do {
                chunk = try await Vault.readAt(session, path: path, offset: offset, len: length)
            } catch {
                failure = error
                break
            }
            if chunk.isEmpty { break }
            // Answers go out on the delegate queue, in order.
            let delivered = queue.sync { () -> Bool in
                guard !stopped, !loadingRequest.isCancelled, !loadingRequest.isFinished else { return false }
                dataRequest.respond(with: chunk)
                return true
            }
            if !delivered { return }
            offset += UInt64(chunk.count)
        }
        if Task.isCancelled { return }
        queue.sync {
            tasks[key] = nil
            guard !stopped, !loadingRequest.isCancelled, !loadingRequest.isFinished else { return }
            if let failure {
                loadingRequest.finishLoading(with: failure)
            } else {
                loadingRequest.finishLoading()
            }
        }
    }
}

/// The player screen. AVKit's controller with Now Playing updates and
/// picture in picture turned off; audio files get the same controls with
/// no picture.
struct MediaPlayerView: View {
    let path: String
    let name: String

    @Environment(SessionRegistry.self) private var sessionRegistry
    @State private var media: VaultMediaPlayer?
    /// The path `media` plays, so a reappearance (AVKit's full screen can
    /// make this view disappear and appear again) doesn't restart it.
    @State private var openedPath: String?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView("Can't play this file.", systemImage: "exclamationmark.triangle")
            } else if let media {
                PlayerControllerView(media: media)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView()
            }
        }
        // Opens the file, and a new one when the path changes. Playback
        // isn't stopped on disappear: the player controller stops it when
        // it goes away for good, and every player stops at lock.
        .task(id: path) {
            await open()
        }
    }

    @MainActor
    private func open() async {
        if media != nil, openedPath == path, !failed {
            return
        }
        media?.stop()
        media = nil
        openedPath = nil
        failed = false
        guard let session = sessionRegistry.session else {
            failed = true
            return
        }
        let size: UInt64
        do {
            size = try await Vault.stat(session, path: path).size
        } catch {
            failed = true
            return
        }
        guard !Task.isCancelled else { return }
        guard let opened = VaultMediaPlayer(session: session, path: path, name: name, size: size),
              let item = opened.player.currentItem
        else {
            failed = true
            return
        }
        media = opened
        openedPath = path
        for await status in item.publisher(for: \.status).values {
            if status == .failed {
                opened.stop()
                failed = true
                break
            }
            if status == .readyToPlay {
                break
            }
        }
    }
}

private struct PlayerControllerView: UIViewControllerRepresentable {
    let media: VaultMediaPlayer

    final class Coordinator {
        var media: VaultMediaPlayer

        init(media: VaultMediaPlayer) {
            self.media = media
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(media: media)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        // No title or artwork from the file reaches the Lock Screen or
        // Control Center.
        controller.updatesNowPlayingInfoCenter = false
        controller.allowsPictureInPicturePlayback = false
        controller.player = media.player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if context.coordinator.media !== media {
            // Another file: the old one stops and lets go of the vault.
            context.coordinator.media.stop()
            context.coordinator.media = media
        }
        if controller.player !== media.player {
            controller.player = media.player
        }
    }

    /// The viewer closed (not a trip to full screen): stop.
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.media.stop()
        controller.player = nil
    }
}
