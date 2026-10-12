//
//  SoundRecorder.swift
//  LidAngleSensor
//
//  Records a custom loop sound from the microphone.
//

import AVFoundation
import Foundation

@Observable
final class SoundRecorder {

    // MARK: Published State

    private(set) var isRecording = false
    private(set) var level = 0.0          // 0...1, input meter
    private(set) var elapsed = 0.0        // seconds recorded so far
    private(set) var errorMessage: String?

    /// Recording stops automatically after this many seconds.
    static let maxDuration: TimeInterval = 10

    /// Called on the main actor with the final file URL once a recording is saved.
    @ObservationIgnored var onFinished: ((URL) -> Void)?

    // MARK: Private

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTimer: Timer?

    // MARK: Storage

    /// ~/Library/Application Support/LidAngleSensor/CustomSound.wav
    static var customSoundURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LidAngleSensor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("CustomSound.wav")
    }

    static var hasCustomSound: Bool {
        FileManager.default.fileExists(atPath: customSoundURL.path)
    }

    private static var tempURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LidAngleSensor-recording.wav")
    }

    // MARK: Control

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        errorMessage = nil

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if granted {
                    beginRecording()
                } else {
                    errorMessage = "Microphone access denied."
                }
            }
        default:
            errorMessage = "Microphone access denied. Allow it in System Settings → Privacy & Security → Microphone."
        }
    }

    func stop() {
        guard isRecording, let recorder else { return }
        recorder.stop()
        finish()
    }

    func deleteCustomSound() {
        try? FileManager.default.removeItem(at: Self.customSoundURL)
    }

    // MARK: Recording

    private func beginRecording() {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        try? FileManager.default.removeItem(at: Self.tempURL)

        do {
            let recorder = try AVAudioRecorder(url: Self.tempURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                errorMessage = "Could not start recording."
                return
            }
            self.recorder = recorder
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            return
        }

        isRecording = true
        elapsed = 0
        level = 0

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        let db = Double(recorder.averagePower(forChannel: 0))
        level = min(1, max(0, pow(10, db / 20) * 2))
        elapsed = recorder.currentTime

        if elapsed >= Self.maxDuration {
            stop()
        }
    }

    private func finish() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        isRecording = false
        level = 0

        let destination = Self.customSoundURL
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: Self.tempURL, to: destination)
            onFinished?(destination)
        } catch {
            errorMessage = "Could not save recording: \(error.localizedDescription)"
        }
    }
}
