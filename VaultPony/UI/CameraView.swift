import AVFoundation
import SwiftUI
import UIKit

// The camera screen (2.0.0 rc5, plan 5.6): full screen from the browser's
// add menu, only for a writable volume and only in the main app (never the
// File Provider or Share extensions). Captures land in the folder the
// browser shows; the camera stays open for more. See CameraEngine for how
// nothing leaves the vault.
//
// Locks: while a recording or a save is in progress the auto-lock waits for
// it (as for a copy, D13). Any lock that does happen first discards an
// unfinished video (SessionRegistry.cameraWillLock), then the screen
// closes. Going to the background stops a recording and keeps it, if the
// vault is still unlocked.

/// A recording in progress: where it is going, and its writer to the vault.
private final class Recording {
    let name: String
    let temp: String
    let sink: SegmentSink
    let session: VaultSession

    init(name: String, temp: String, sink: SegmentSink, session: VaultSession) {
        self.name = name
        self.temp = temp
        self.sink = sink
        self.session = session
    }
}

@MainActor
@Observable
final class CameraModel {
    private(set) var mode: CameraMode
    private(set) var cameraDenied = false
    private(set) var canSwitchCamera = false
    private(set) var isRecording = false
    private(set) var recordingSince: Date?
    /// A capture is being started, stopped or saved.
    private(set) var isBusy = false
    /// A short message over the preview ("Saved to …").
    private(set) var notice: String?
    /// The screen should close (Close was tapped during a recording, which
    /// is saved first).
    private(set) var wantsDismiss = false

    let engine = CameraEngine()
    private let folder: String
    private let folderLabel: String
    @ObservationIgnored private weak var registry: SessionRegistry?
    @ObservationIgnored private var position: AVCaptureDevice.Position = .back
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var recording: Recording?
    @ObservationIgnored private var saidNoSound = false
    @ObservationIgnored private var closeAfterRecording = false
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(mode: CameraMode, folder: String, folderLabel: String, registry: SessionRegistry) {
        self.mode = mode
        self.folder = folder
        self.folderLabel = folderLabel
        self.registry = registry
    }

    /// The session this screen writes into, while it is still the open one.
    private var session: VaultSession? {
        guard let session = registry?.session, registry?.facts?.writable == true else { return nil }
        return session
    }

    private func isOpen(_ session: VaultSession) -> Bool {
        registry?.session === session
    }

    // MARK: Setup

    /// Asks for the camera the first time, and for the microphone the
    /// first time Video is chosen, then starts the preview.
    func start() async {
        canSwitchCamera = CameraEngine.hasFrontAndBack
        guard await Self.cameraAllowed() else {
            cameraDenied = true
            return
        }
        if mode == .video {
            await settleMicrophone()
        }
        configure()
    }

    private static func cameraAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    /// Video without the microphone records without sound, said once.
    private func settleMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized, !saidNoSound {
            saidNoSound = true
            show(String(localized: "Recording without sound. Allow the microphone to record sound.", locale: LanguageOverride.locale))
        }
    }

    private func configure() {
        let audio = mode == .video && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        engine.configure(mode: mode, position: position, audio: audio) { [weak self] device in
            self?.configured(device)
        }
    }

    private func configured(_ device: AVCaptureDevice?) {
        self.device = device
        updateRotation()
    }

    /// The preview layer exists (CameraPreview made it).
    func previewLayerReady(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        updateRotation()
    }

    /// Keeps the preview level as the device turns, and tells captures how
    /// to rotate (iOS 17 rotation coordinator).
    private func updateRotation() {
        guard let device, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in
                self?.applyPreviewRotation(angle)
            }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private var captureRotation: CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
    }

    func setMode(_ newMode: CameraMode) async {
        guard newMode != mode, !isRecording, !isBusy else { return }
        mode = newMode
        if newMode == .video {
            await settleMicrophone()
        }
        configure()
    }

    func switchCamera() {
        guard canSwitchCamera, !isRecording, !isBusy else { return }
        position = position == .back ? .front : .back
        configure()
    }

    // MARK: Photo

    func takePhoto() {
        guard let session, !isBusy, !isRecording else { return }
        isBusy = true
        let name = CaptureStore.fileName(prefix: "IMG", ext: "jpg", date: Date())
        registry?.holdAutoLock()
        engine.capturePhoto(rotation: captureRotation) { [weak self] data in
            Task { @MainActor in
                await self?.storePhoto(data, name: name, session: session)
            }
        }
    }

    private func storePhoto(_ data: Data?, name: String, session: VaultSession) async {
        defer {
            isBusy = false
            registry?.releaseAutoLock()
            closeIfAsked()
        }
        guard let data, isOpen(session) else { return }
        do {
            _ = try await CaptureStore.savePhoto(data, name: name, folder: folder, session: session)
            showSaved()
        } catch {
            guard isOpen(session) else { return }
            show((error as? VaultError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: Video

    func startRecording() async {
        guard let session, !isBusy, !isRecording else { return }
        isBusy = true
        let name = CaptureStore.fileName(prefix: "VID", ext: "mp4", date: Date())
        let temp = TransferIO.partialPath(beside: VaultPath.join(folder, name))
        do {
            try await Vault.create(session, path: temp)
        } catch {
            isBusy = false
            show((error as? VaultError)?.message ?? error.localizedDescription)
            closeIfAsked()
            return
        }
        guard isOpen(session) else {
            isBusy = false
            closeIfAsked()
            return
        }
        let sink = SegmentSink(session: session, path: temp)
        let current = Recording(name: name, temp: temp, sink: sink, session: session)
        recording = current
        registry?.holdAutoLock()
        engine.startRecording(rotation: captureRotation, onSegment: { @Sendable segment in
            sink.append(segment)
        }, completion: { [weak self] started in
            self?.recordingStarted(current, started: started)
        })
    }

    private func recordingStarted(_ current: Recording, started: Bool) {
        guard recording === current else { return }
        isBusy = false
        if started {
            isRecording = true
            recordingSince = Date()
            // Close was tapped while it was starting: save it and close.
            if closeAfterRecording {
                stopRecording()
            }
        } else {
            recording = nil
            Task { await discard(current, showError: true) }
            closeIfAsked()
        }
    }

    /// The stop button, Close during a recording, or the app going to the
    /// background: finish the movie and keep it.
    func stopRecording() {
        guard isRecording, let current = recording else { return }
        isRecording = false
        recordingSince = nil
        isBusy = true
        engine.stopRecording { [weak self] finished in
            Task { @MainActor in
                await self?.finishRecording(current, writerFinished: finished)
            }
        }
    }

    private func finishRecording(_ current: Recording, writerFinished: Bool) async {
        let written = try? await current.sink.finish()
        guard recording === current, isOpen(current.session) else {
            // A lock got here first and discarded it.
            endRecording()
            return
        }
        if writerFinished, let written, written > 0 {
            do {
                _ = try await CaptureStore.finish(temp: current.temp, name: current.name, folder: folder, session: current.session)
                showSaved()
                endRecording()
                return
            } catch {
                // Falls through to discarding it.
            }
        }
        recording = nil
        await discard(current, showError: true)
        endRecording()
    }

    /// Removes an unfinished video's temporary file.
    private func discard(_ current: Recording, showError: Bool) async {
        current.sink.abandon()
        if isOpen(current.session) {
            try? await Vault.remove(current.session, path: current.temp)
            try? await Vault.flush(current.session)
        }
        if showError {
            show(String(localized: "Couldn't save the video.", locale: LanguageOverride.locale))
        }
        if recording == nil {
            registry?.releaseAutoLock()
        }
    }

    private func endRecording() {
        if recording != nil {
            recording = nil
            registry?.releaseAutoLock()
        }
        isBusy = false
        endBackgroundWindow()
        closeIfAsked()
    }

    /// Close was tapped while a capture was busy: close now it is done.
    private func closeIfAsked() {
        if closeAfterRecording {
            wantsDismiss = true
        }
    }

    // MARK: Leaving

    /// Close: a recording is saved first.
    func close() {
        if isRecording {
            closeAfterRecording = true
            stopRecording()
        } else if !isBusy {
            wantsDismiss = true
        } else {
            closeAfterRecording = true
        }
    }

    /// The app is going to the background: finish and keep a recording
    /// while the vault is still unlocked (its hold keeps the auto-lock
    /// waiting until then).
    func appDidEnterBackground() {
        guard isRecording else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VaultPony camera") { [weak self] in
                MainActor.assumeIsolated {
                    self?.backgroundTimeExpired()
                }
            }
        }
        stopRecording()
    }

    /// Out of background time before the video was stored: lock now (which
    /// discards it, below) rather than leave the vault open with the
    /// auto-lock held off, as a copy does.
    private func backgroundTimeExpired() {
        if recording != nil {
            registry?.lock()
        }
        endBackgroundWindow()
    }

    /// SessionRegistry.lock, before the keys go: stop and discard an
    /// unfinished video. The temporary file is removed here and now, in one
    /// gated call, because the vault can't be reached once this returns.
    func vaultWillLock() {
        if let current = recording {
            recording = nil
            isRecording = false
            recordingSince = nil
            engine.cancelRecording()
            current.sink.abandon()
            _ = try? FilesGate.shared.perform(current.session, write: true) {
                try current.session.remove(path: current.temp)
            }
        }
        isBusy = false
        engine.shutDown()
        endBackgroundWindow()
    }

    /// The screen went away.
    func shutDown() {
        if let current = recording {
            // Closed without a lock (should not happen with Close, which
            // saves first): drop the unfinished video.
            recording = nil
            isRecording = false
            engine.cancelRecording()
            Task { await discard(current, showError: false) }
        }
        noticeTask?.cancel()
        rotationObservation = nil
        engine.shutDown()
        endBackgroundWindow()
    }

    private func endBackgroundWindow() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Messages

    private func showSaved() {
        show(String(localized: "Saved to \(folderLabel)", locale: LanguageOverride.locale))
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

/// Full-screen camera: preview, close, Photo/Video, shutter or record/stop,
/// and Switch camera when there is more than one.
struct CameraView: View {
    let initialMode: CameraMode
    /// The browser's folder.
    let folder: String
    /// Its name, or the vault's at the root, for "Saved to".
    let folderLabel: String

    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: CameraModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                if model.cameraDenied {
                    denied
                } else {
                    CameraPreview(session: model.engine.session) { layer in
                        // Not during the view update that made it.
                        Task { @MainActor in model.previewLayerReady(layer) }
                    }
                    .ignoresSafeArea()
                    controls(model)
                }
            }
        }
        .statusBarHidden()
        .onAppear {
            guard model == nil else { return }
            guard sessionRegistry.session != nil, sessionRegistry.facts?.writable == true else {
                dismiss()
                return
            }
            let made = CameraModel(mode: initialMode, folder: folder, folderLabel: folderLabel, registry: sessionRegistry)
            model = made
            sessionRegistry.cameraWillLock = { [weak made] in
                made?.vaultWillLock()
            }
            Task { await made.start() }
        }
        .onDisappear {
            sessionRegistry.cameraWillLock = nil
            model?.shutDown()
        }
        .onChange(of: sessionRegistry.lockGeneration) { _, _ in
            dismiss()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model?.appDidEnterBackground()
            }
        }
        .onChange(of: model?.wantsDismiss ?? false) { _, wants in
            if wants {
                dismiss()
            }
        }
    }

    private var denied: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera")
                .font(.system(size: 44))
            Text("VaultPony needs the camera to take photos into the vault.")
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Close") {
                dismiss()
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    @MainActor
    private func controls(_ model: CameraModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2)
                        .padding(12)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .accessibilityLabel("Close")
                Spacer()
                if let since = model.recordingSince {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                        Text(since, style: .timer)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
                }
                Spacer()
                if model.canSwitchCamera {
                    Button {
                        model.switchCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title2)
                            .padding(12)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .accessibilityLabel("Switch camera")
                    .disabled(model.isRecording || model.isBusy)
                } else {
                    Color.clear.frame(width: 48, height: 48)
                }
            }
            .padding()

            Spacer()

            if let notice = model.notice {
                Text(verbatim: notice)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }

            Picker("Mode", selection: Binding(
                get: { model.mode },
                set: { picked in Task { await model.setMode(picked) } }
            )) {
                Text("Photo").tag(CameraMode.photo)
                Text("Video").tag(CameraMode.video)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .disabled(model.isRecording || model.isBusy)
            .padding(.bottom, 16)

            shutter(model)
                .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
    }

    @MainActor
    @ViewBuilder
    private func shutter(_ model: CameraModel) -> some View {
        switch model.mode {
        case .photo:
            Button {
                model.takePhoto()
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 66, height: 66)
                    .overlay(Circle().stroke(.white, lineWidth: 4).padding(-6))
            }
            .accessibilityLabel("Take photo")
            .disabled(model.isBusy)
        case .video:
            Button {
                if model.isRecording {
                    model.stopRecording()
                } else {
                    Task { await model.startRecording() }
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 62, height: 62)
                    }
                }
            }
            .accessibilityLabel(model.isRecording ? Text("Stop") : Text("Record video"))
            .disabled(model.isBusy)
        }
    }
}

/// The live preview, an AVCaptureVideoPreviewLayer in a UIView.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onLayer: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        onLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass makes this cast always succeed.
        layer as! AVCaptureVideoPreviewLayer
    }
}
