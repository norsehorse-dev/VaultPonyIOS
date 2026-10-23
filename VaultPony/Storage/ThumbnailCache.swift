import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Grid thumbnails (2.0.0 rc4, plan 5.3). Decoded in memory from the vault
/// through `Vault.readAt`, downsampled with ImageIO, and kept only in this
/// in-memory cache: never written to disk, and dropped at every lock
/// (SessionRegistry.lock).
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    /// About 32 MB of decoded pixels.
    static let costLimit = 32 << 20

    private let lock = NSLock()
    private var images: [String: UIImage] = [:]
    private var costs: [String: Int] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var totalCost = 0
    /// Bumped at every clear, so a decode that started before a lock can't
    /// put its result back afterwards.
    private var generation = 0

    var currentGeneration: Int {
        lock.withLock { generation }
    }

    func image(for key: String) -> UIImage? {
        lock.withLock {
            guard let image = images[key] else { return nil }
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
            }
            order.append(key)
            return image
        }
    }

    func insert(_ image: UIImage, cost: Int, for key: String, generation: Int) {
        lock.withLock {
            guard generation == self.generation, cost <= Self.costLimit else { return }
            if let old = costs[key] {
                totalCost -= old
                order.removeAll { $0 == key }
            }
            images[key] = image
            costs[key] = cost
            order.append(key)
            totalCost += cost
            while totalCost > Self.costLimit, !order.isEmpty {
                let evicted = order.removeFirst()
                images[evicted] = nil
                totalCost -= costs.removeValue(forKey: evicted) ?? 0
            }
        }
    }

    func removeAll() {
        lock.withLock {
            images.removeAll()
            costs.removeAll()
            order.removeAll()
            totalCost = 0
            generation += 1
        }
    }
}

/// Lets a few tasks at a time through. Thumbnails use it so only two
/// source files (up to 20 MB each) are in memory at once.
actor AsyncGate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running = max(running - 1, 0)
        } else {
            // The slot passes straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}

enum Thumbnails {
    /// Larger files get the file icon instead of a thumbnail.
    static let maxSourceBytes: UInt64 = 20 << 20
    /// Longest side of a thumbnail, in pixels.
    static let maxPixelSize = 320

    private static let gate = AsyncGate(limit: 2)
    private static let readChunk: UInt32 = 4 << 20

    private static let knownExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif"]
    /// Every type this device's ImageIO can decode.
    private static let decodableTypes: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    /// Images by extension: the common ones, plus whatever ImageIO decodes.
    static func canThumbnail(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if knownExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext), type.conforms(to: .image) else { return false }
        return decodableTypes.contains(type.identifier)
    }

    /// The cache key: the path plus what changes when the file does.
    static func key(path: String, entry: DirEntry) -> String {
        "\(path)\u{0}\(entry.size)\u{0}\(entry.mtimeMs ?? 0)"
    }

    /// A thumbnail for the vault file at `path`, from the cache or decoded
    /// now. nil for anything that isn't a decodable image under 20 MB, and
    /// when the calling task is cancelled.
    static func load(session: VaultSession, path: String, entry: DirEntry) async -> UIImage? {
        guard !entry.isDir, entry.size > 0, entry.size <= maxSourceBytes, canThumbnail(entry.name) else { return nil }
        let cacheKey = Self.key(path: path, entry: entry)
        if let cached = ThumbnailCache.shared.image(for: cacheKey) {
            return cached
        }
        let generation = ThumbnailCache.shared.currentGeneration
        await gate.acquire()
        let image = await decode(session: session, path: path, size: entry.size, key: cacheKey, generation: generation)
        await gate.release()
        return image
    }

    private static func decode(session: VaultSession, path: String, size: UInt64, key: String, generation: Int) async -> UIImage? {
        if let cached = ThumbnailCache.shared.image(for: key) {
            return cached
        }
        guard !Task.isCancelled else { return nil }
        var data = Data()
        data.reserveCapacity(Int(size))
        var offset: UInt64 = 0
        while offset < size {
            guard !Task.isCancelled,
                  let chunk = try? await Vault.readAt(session, path: path, offset: offset, len: readChunk),
                  !chunk.isEmpty
            else { break }
            data.append(chunk)
            offset += UInt64(chunk.count)
        }
        guard !Task.isCancelled, !data.isEmpty else { return nil }
        let bytes = data
        let result = await Task.detached(priority: .utility) { () -> (UIImage, Int)? in
            Thumbnails.downsample(bytes)
        }.value
        guard let result else { return nil }
        let (image, cost) = result
        ThumbnailCache.shared.insert(image, cost: cost, for: key, generation: generation)
        return image
    }

    /// ImageIO straight to a small bitmap; the full-size image is never
    /// decoded and nothing is cached by ImageIO itself.
    private static func downsample(_ data: Data) -> (UIImage, Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        return (UIImage(cgImage: cgImage), cgImage.bytesPerRow * cgImage.height)
    }
}
