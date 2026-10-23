import AVFoundation
import Foundation
import UniformTypeIdentifiers

// Camera capture into the vault (2.0.0 rc5, plan 5.6, D10, D11). Nothing
// a capture makes is ever written outside the vault:
//
// - Photos come back from AVCapturePhotoOutput as JPEG bytes in memory
//   (`fileDataRepresentation()`) and are written into the vault.
// - Video and sound go from AVCaptureVideoDataOutput and
//   AVCaptureAudioDataOutput into an AVAssetWriter made with a content type
//   and no URL. With the Apple HLS profile it hands back fragmented MP4 in
//   memory, one segment at a time (the init segment first, then a segment
//   about every 2 seconds), and each segment is appended in order to a
//   temporary file in the vault. There is no temp file on disk at any point.
//
// A capture is written under ".vaultpony-<token>.part" beside its final
// name and `replace`d to "IMG_yyyyMMdd_HHmmss.jpg" or
// "VID_yyyyMMdd_HHmmss.mp4" when complete, so a crash never leaves a half
// file under the real name. Nothing adds location metadata.

/// Which capture the camera screen is set up for.
enum CameraMode: String, Identifiable {
    case photo
    case video

    var id: String { rawValue }
}

// MARK: - Writing captures into the vault

enum CaptureStore {
    /// "IMG_20261023_142501.jpg": local time, ASCII digits whatever the
    /// device's calendar.
    static func fileName(prefix: String, ext: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(formatter.string(from: date)).\(ext)"
    }

    /// `name`, or "name (1)" and so on when the folder already has it
    /// (D6; FAT and exFAT compare names without regard to case).
    static func freeName(_ name: String, in folder: String, session: VaultSession) async throws -> String {
        let entries = try await Vault.list(session, path: folder)
        let taken = Set(entries.map { TransferNaming.fold($0.name) })
        guard taken.contains(TransferNaming.fold(name)) else { return name }
        return TransferNaming.keepBothName(for: name) { taken.contains(TransferNaming.fold($0)) }
    }

    /// Writes a photo held in memory into `folder`. Returns the name used.
    static func savePhoto(_ data: Data, name: String, folder: String, session: VaultSession) async throws -> String {
        let temp = TransferIO.partialPath(beside: VaultPath.join(folder, name))
        try await Vault.create(session, path: temp)
        do {
            var start = data.startIndex
            var offset: UInt64 = 0
            while start < data.endIndex {
                let end = min(start + TransferIO.chunkBytes, data.endIndex)
                try await Vault.writeAt(session, path: temp, offset: offset, data: Data(data[start..<end]))
                offset += UInt64(end - start)
                start = end
            }
            return try await finish(temp: temp, name: name, folder: folder, session: session)
        } catch {
            try? await Vault.remove(session, path: temp)
            throw error
        }
    }

    /// Puts a finished temporary file in place under a free name, then
    /// flushes (which also tells Files). Returns the name used.
    static func finish(temp: String, name: String, folder: String, session: VaultSession) async throws -> String {
        let finalName = try await freeName(name, in: folder, session: session)
        try await Vault.replace(session, src: temp, dst: VaultPath.join(folder, finalName))
        try await Vault.flush(session)
        return finalName
    }
}

/// Appends a recording's segments, in the order they arrive, to its
/// temporary file in the vault through `Vault.writeAt`. `append` may be
/// called from any thread.
final class SegmentSink: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let task: Task<UInt64, Error>

    init(session: VaultSession, path: String) {
        var made: AsyncStream<Data>.Continuation?
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { made = $0 }
        continuation = made!
        task = Task.detached(priority: .userInitiated) {
            var offset: UInt64 = 0
            var failure: Error?
            for await segment in stream {
                // After a failed write the rest is drained, not written.
                guard failure == nil else { continue }
                do {
                    var start = segment.startIndex
                    while start < segment.endIndex {
                        let end = min(start + TransferIO.chunkBytes, segment.endIndex)
                        try await Vault.writeAt(session, path: path, offset: offset, data: Data(segment[start..<end]))
                        offset += UInt64(end - start)
                        start = end
                    }
                } catch {
                    failure = error
                }
            }
            if let failure { throw failure }
            return offset
        }
    }

    func append(_ segment: Data) {
        continuation.yield(segment)
    }

    /// No more segments: waits for the last write and returns the bytes
    /// written, or throws the first write error.
    func finish() async throws -> UInt64 {
        continuation.finish()
        return try await task.value
    }

    /// Drops whatever hasn't been written yet.
    func abandon() {
        continuation.finish()
        task.cancel()
    }
}

// MARK: - Video: fragmented MP4 in memory

/// One recording. Everything but `init` runs on the engine's data queue.
final class SegmentRecorder: NSObject, AVAssetWriterDelegate {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let onSegment: (Data) -> Void
    private var started = false
    private var failed = false
    private var finishing = false

    /// `rotation` is the capture rotation angle in degrees (0, 90, 180,
    /// 270), written into the track as its display transform.
    init(videoSettings: [String: Any], audioSettings: [String: Any]?, rotation: CGFloat, onSegment: @escaping (Data) -> Void) {
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 1)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        video.transform = CGAffineTransform(rotationAngle: rotation * .pi / 180)
        videoInput = video

        if let audioSettings {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            audioInput = audio
        } else {
            audioInput = nil
        }
        self.onSegment = onSegment
        super.init()

        writer.delegate = self
        if writer.canAdd(video) {
            writer.add(video)
        } else {
            failed = true
        }
        if let audioInput, writer.canAdd(audioInput) {
            writer.add(audioInput)
        }
    }

    /// A video frame or a piece of sound. The movie starts at the first
    /// video frame; sound before it is dropped.
    func append(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        guard !failed, !finishing else { return }
        if !started {
            guard isVideo else { return }
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.initialSegmentStartTime = start
            guard writer.startWriting() else {
                failed = true
                return
            }
            writer.startSession(atSourceTime: start)
            started = true
        }
        guard writer.status == .writing else {
            failed = true
            return
        }
        guard let input = isVideo ? videoInput : audioInput, input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer), writer.status == .failed {
            failed = true
        }
    }

    /// Ends the movie. `completion` gets true when the whole movie was
    /// written; by then its last segment has gone to `onSegment`.
    func finish(completion: @escaping (Bool) -> Void) {
        guard !finishing else { return }
        finishing = true
        guard started, !failed, writer.status == .writing else {
            cancelWriting()
            completion(false)
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let writer = self.writer
        writer.finishWriting {
            completion(writer.status == .completed)
        }
    }

    /// Stops without finishing the movie.
    func cancel() {
        finishing = true
        cancelWriting()
    }

    private func cancelWriting() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    // MARK: AVAssetWriterDelegate

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        onSegment(segmentData)
    }
}

// MARK: - Photos

/// Holds a photo's JPEG bytes until the capture is over.
private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let done: (Data?) -> Void
    private var data: Data?

    init(done: @escaping (Data?) -> Void) {
        self.done = done
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        data = error == nil ? photo.fileDataRepresentation() : nil
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        done(error == nil ? data : nil)
    }
}

// MARK: - The capture session

/// AVFoundation side of the camera screen. The session is configured on
/// `sessionQueue`; frames and sound arrive on `dataQueue`, which also owns
/// the recorder. Completions come back on the main queue.
final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "dev.norsehorse.vaultpony.camera.session")
    private let dataQueue = DispatchQueue(label: "dev.norsehorse.vaultpony.camera.data")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // sessionQueue only.
    private var cameraInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var photoDelegates: [Int64: PhotoDelegate] = [:]

    // dataQueue only.
    private var recorder: SegmentRecorder?

    override init() {
        super.init()
        // Recording wants every frame; late ones are not dropped.
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
    }

    static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Front and back cameras both there: "Switch camera" is offered.
    static var hasFrontAndBack: Bool {
        camera(at: .front) != nil && camera(at: .back) != nil
    }

    /// Sets the session up for `mode` with the camera at `position` (and the
    /// microphone for video when `audio`), and starts it. `completion` gets
    /// the camera in use, or nil if none could be opened.
    func configure(mode: CameraMode, position: AVCaptureDevice.Position, audio: Bool, completion: @escaping (AVCaptureDevice?) -> Void) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            if let input = cameraInput {
                session.removeInput(input)
                cameraInput = nil
            }
            if let input = microphoneInput {
                session.removeInput(input)
                microphoneInput = nil
            }
            for output in session.outputs {
                session.removeOutput(output)
            }

            var device = Self.camera(at: position) ?? AVCaptureDevice.default(for: .video)
            if let camera = device, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
                session.addInput(input)
                cameraInput = input
            } else {
                device = nil
            }

            switch mode {
            case .photo:
                if session.canAddOutput(photoOutput) {
                    session.addOutput(photoOutput)
                }
                if session.canSetSessionPreset(.photo) {
                    session.sessionPreset = .photo
                }
            case .video:
                if session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                }
                if audio,
                   let microphone = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: microphone),
                   session.canAddInput(input) {
                    session.addInput(input)
                    microphoneInput = input
                    if session.canAddOutput(audioOutput) {
                        session.addOutput(audioOutput)
                    }
                }
                if session.canSetSessionPreset(.high) {
                    session.sessionPreset = .high
                }
            }
            session.commitConfiguration()
            if !session.isRunning {
                session.startRunning()
            }
            let result = device
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Takes a JPEG in memory. `rotation` is the capture rotation angle in
    /// degrees. `completion` gets the bytes, or nil if the capture failed.
    func capturePhoto(rotation: CGFloat, completion: @escaping (Data?) -> Void) {
        sessionQueue.async { [self] in
            // capturePhoto raises an exception without an active, enabled
            // video connection (no camera input, or the session interrupted).
            guard session.outputs.contains(where: { $0 === photoOutput }),
                  let connection = photoOutput.connection(with: .video),
                  connection.isEnabled, connection.isActive else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let settings: AVCapturePhotoSettings
            if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            if connection.isVideoRotationAngleSupported(rotation) {
                connection.videoRotationAngle = rotation
            }
            let id = settings.uniqueID
            let delegate = PhotoDelegate { [weak self] data in
                self?.sessionQueue.async { self?.photoDelegates[id] = nil }
                DispatchQueue.main.async { completion(data) }
            }
            photoDelegates[id] = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    /// Starts a recording whose segments go to `onSegment` (from any
    /// queue, in order). `completion` gets false if it couldn't start.
    func startRecording(rotation: CGFloat, onSegment: @escaping (Data) -> Void, completion: @escaping (Bool) -> Void) {
        dataQueue.async { [self] in
            guard recorder == nil,
                  videoOutput.connection(with: .video) != nil,
                  let videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mp4) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            var audioSettings: [String: Any]?
            if audioOutput.connection(with: .audio) != nil,
               var settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) as? [String: Any] {
                settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
                audioSettings = settings
            }
            recorder = SegmentRecorder(videoSettings: videoSettings, audioSettings: audioSettings, rotation: rotation, onSegment: onSegment)
            DispatchQueue.main.async { completion(true) }
        }
    }

    /// Ends the recording. `completion` gets true when the whole movie was
    /// written and every segment has gone to `onSegment`.
    func stopRecording(completion: @escaping (Bool) -> Void) {
        dataQueue.async { [self] in
            guard let current = recorder else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            recorder = nil
            current.finish { finished in
                // The writer only holds its delegate weakly: keep the
                // recorder until the last segment is out.
                withExtendedLifetime(current) {}
                DispatchQueue.main.async { completion(finished) }
            }
        }
    }

    /// Drops a recording without finishing it.
    func cancelRecording() {
        dataQueue.async { [self] in
            recorder?.cancel()
            recorder = nil
        }
    }

    /// The camera screen is going: stop everything.
    func shutDown() {
        cancelRecording()
        sessionQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: Sample buffers (dataQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recorder?.append(sampleBuffer, isVideo: output === videoOutput)
    }
}
