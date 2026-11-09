import AVFoundation

@MainActor
public protocol DictationRecording: AnyObject {
    /// Called when recording ends without the user asking: a phone call,
    /// a route change, an encoder error. The file holds what was captured.
    var onInterrupted: (@MainActor () -> Void)? { get set }
    func requestPermission() async -> Bool
    func start(to file: URL) throws
    func stop()
}

@MainActor
public final class DictationRecorder: DictationRecording {
    public var onInterrupted: (@MainActor () -> Void)?
    private var recorder: AVAudioRecorder?
    private var observers: [any NSObjectProtocol] = []
    private let delegate = Delegate()

    public init() {
        delegate.owner = self
    }

    public func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func start(to file: URL) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        do {
            let recorder = try AVAudioRecorder(url: file, settings: settings)
            recorder.delegate = delegate
            guard recorder.record() else { throw URLError(.cannotCreateFile) }
            self.recorder = recorder
            try? FileManager.default.setAttributes([.protectionKey: PendingRecordingStore.protection], ofItemAtPath: file.path)
        } catch {
            // The session was activated above: release it, or other apps stay ducked.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        observe()
    }

    public func stop() {
        removeObservers()
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    fileprivate func interrupted() {
        guard recorder != nil else { return }
        onInterrupted?()
    }

    /// A delegate callback may arrive late, from a recorder that was already
    /// stopped: it must not end the recording that replaced it.
    fileprivate func interrupted(by id: ObjectIdentifier) {
        guard let recorder, ObjectIdentifier(recorder) == id else { return }
        onInterrupted?()
    }

    private func observe() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.interrupted() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.interrupted() }
        })
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private final class Delegate: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
        weak var owner: DictationRecorder?

        func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
            let id = ObjectIdentifier(recorder)
            Task { @MainActor in self.owner?.interrupted(by: id) }
        }

        func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
            let id = ObjectIdentifier(recorder)
            Task { @MainActor in self.owner?.interrupted(by: id) }
        }
    }
}
