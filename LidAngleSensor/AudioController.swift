//
//  AudioController.swift
//  LidAngleSensor
//
//  Created by Sam on 2026-03-22.
//

import SwiftUI

extension EnvironmentValues {
    @Entry var audioController: AudioController = .init()
}

@MainActor
@Observable
final class AudioController {
    
    // MARK: Published State
    
    private(set) var isPlaying = false
    
    var mode: AudioMode = .creak {
        didSet {
            guard oldValue != mode else { return }
            modeDidChange(from: oldValue)
        }
    }
    
    // MARK: Engines
    
    let creakEngine = CreakAudioEngine()
    let thereminEngine = ThereminAudioEngine()
    let customEngine = CreakAudioEngine(
        soundURL: SoundRecorder.hasCustomSound ? SoundRecorder.customSoundURL : nil,
        prepareForLoop: true
    )
    let recorder = SoundRecorder()

    init() {
        recorder.onFinished = { [weak self] url in
            guard let self else { return }
            self.customEngine.load(url: url, prepareForLoop: true)
            self.mode = .custom
        }
    }

    /// Play is unavailable in Custom mode until a sound has been recorded.
    var canPlay: Bool {
        mode != .custom || customEngine.hasSound
    }
    
    // MARK: Control
    
    func toggle() {
        guard isPlaying || canPlay else { return }
        if isPlaying {
            engine(for: mode).stop()
        } else {
            engine(for: mode).start()
        }
        isPlaying.toggle()
    }
    
    func feed(angle: Double, velocity: Double) {
        guard isPlaying else { return }
        switch mode {
        case .creak:
            creakEngine.update(velocity: velocity)
        case .theremin:
            thereminEngine.update(angle: angle, velocity: velocity)
        case .custom:
            customEngine.update(velocity: velocity)
        }
    }
    
    // MARK: Recording

    /// Starts/stops a microphone recording for the Custom sound.
    /// Playback is stopped first so the speakers don't bleed into the recording.
    func toggleRecording() {
        if !recorder.isRecording && isPlaying {
            toggle()
        }
        recorder.toggle()
    }

    func deleteCustomSound() {
        if mode == .custom && isPlaying {
            toggle()
        }
        customEngine.unload()
        recorder.deleteCustomSound()
    }

    // MARK: Private
    
    var activeEngine: any AudioEngineProtocol { engine(for: mode) }
    
    private func engine(for mode: AudioMode) -> any AudioEngineProtocol {
        switch mode {
        case .creak:    creakEngine
        case .theremin: thereminEngine
        case .custom:   customEngine
        }
    }
    
    private func modeDidChange(from oldMode: AudioMode) {
        guard isPlaying else { return }
        engine(for: oldMode).stop()
        if canPlay {
            engine(for: mode).start()
        } else {
            isPlaying = false
        }
    }
}
