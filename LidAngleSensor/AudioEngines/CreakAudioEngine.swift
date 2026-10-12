//
//  CreakAudioEngine.swift
//  LidAngleSensor
//
//  Created by Sam on 2026-03-22.
//

import AVFoundation

@Observable
final class CreakAudioEngine: AudioEngineProtocol {
    
    // MARK: Published State
    
    private(set) var isRunning = false
    private(set) var gain = Double.zero
    private(set) var rate = 1.0
    
    // MARK: Audio Graph
    
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private var loopBuffer: AVAudioPCMBuffer?
    
    // MARK: Ramping State
    
    private var targetGain = Double.zero
    private var targetRate = 1.0
    private var lastRampTime: TimeInterval = 0
    
    // MARK: Parameters
    
    var velocityFull = 10.0
    var velocityQuiet = 100.0
    var minRate = 0.80
    var maxRate = 1.10
    var gainRampMs = 50.0
    var rateRampMs = 80.0
    
    private var deadzone = 1.0
    
    // MARK: Lifecycle
    
    /// Whether a loop sound is loaded and the engine can play.
    var hasSound: Bool { loopBuffer != nil }

    /// Creates an engine that plays the bundled creak loop.
    convenience init() {
        self.init(soundURL: Bundle.main.url(forResource: "CREAK_LOOP", withExtension: "wav"))
    }

    /// Creates an engine that plays the sound at `soundURL` (or nothing if nil).
    /// - Parameter prepareForLoop: trims silence, normalizes and fades the edges
    ///   so a raw microphone recording loops cleanly.
    init(soundURL: URL?, prepareForLoop: Bool = false) {
        engine.attach(playerNode)
        engine.attach(varispeed)

        if let soundURL {
            load(url: soundURL, prepareForLoop: prepareForLoop)
        }
    }

    // MARK: Loading

    /// Loads a new loop sound. Safe to call while playing.
    @discardableResult
    func load(url: URL, prepareForLoop: Bool = false) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? file.read(into: buffer)) != nil else {
            return false
        }

        let wasRunning = isRunning
        if wasRunning { stop() }

        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(varispeed)
        engine.connect(playerNode, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)

        loopBuffer = prepareForLoop ? Self.preparedLoop(from: buffer) : buffer

        if wasRunning { start() }
        return true
    }

    /// Removes the loaded sound (stops playback).
    func unload() {
        stop()
        loopBuffer = nil
    }

    /// Trims leading/trailing silence, normalizes the level and applies short
    /// fades at both ends so the loop doesn't click.
    private static func preparedLoop(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let data = buffer.floatChannelData else { return buffer }
        let channels = Int(buffer.format.channelCount)
        let n = Int(buffer.frameLength)
        guard n > 0, channels > 0 else { return buffer }

        var peak: Float = 0
        for c in 0..<channels {
            for i in 0..<n { peak = max(peak, abs(data[c][i])) }
        }
        guard peak > 0.0001 else { return buffer }

        let threshold = peak * 0.05
        func isLoud(_ i: Int) -> Bool {
            for c in 0..<channels where abs(data[c][i]) > threshold { return true }
            return false
        }

        var start = 0
        while start < n - 1 && !isLoud(start) { start += 1 }
        var end = n - 1
        while end > start && !isLoud(end) { end -= 1 }

        let length = end - start + 1
        guard length > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(length)),
              let outData = out.floatChannelData else {
            return buffer
        }
        out.frameLength = AVAudioFrameCount(length)

        let normalize: Float = 0.5 / peak
        let fade = min(length / 4, Int(buffer.format.sampleRate * 0.015))

        for c in 0..<channels {
            for i in 0..<length {
                var sample = data[c][start + i] * normalize
                if fade > 0 {
                    if i < fade {
                        sample *= Float(i) / Float(fade)
                    } else if i >= length - fade {
                        sample *= Float(length - 1 - i) / Float(fade)
                    }
                }
                outData[c][i] = sample
            }
        }
        return out
    }

    // MARK: Control
    
    func start() {
        guard !isRunning, let buffer = loopBuffer else { return }
        
        try? engine.start()
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
        playerNode.play()
        playerNode.volume = 0
        isRunning = true
    }
    
    func stop() {
        guard isRunning else { return }
        playerNode.stop()
        engine.stop()
        isRunning = false
    }
    
    // MARK: Reset
    
    func resetToDefaults() {
        velocityFull = 10.0
        velocityQuiet = 100.0
        minRate = 0.80
        maxRate = 1.10
        gainRampMs = 50.0
        rateRampMs = 80.0
    }
    
    // MARK: Parameter Update
    
    func update(velocity: Double) {
        let speed = abs(velocity)
        
        // Gain: slow = loud, fast = quiet
        if speed < deadzone {
            targetGain = 0
        } else {
            let e0 = max(0, velocityFull - 0.5)
            let e1 = velocityQuiet + 0.5
            let t = min(1, max(0, (speed - e0) / (e1 - e0)))
            let s = t * t * (3 - 2 * t) // smoothstep
            targetGain = 1 - s
        }
        
        // Rate: speed maps linearly across pitch range
        let normalized = min(1, max(0, speed / velocityQuiet))
        targetRate = minRate + normalized * (maxRate - minRate)
        
        ramp()
    }
    
    private func ramp() {
        guard isRunning else { return }
        
        let now = CACurrentMediaTime()
        let dt = lastRampTime == 0 ? 0.016 : now - lastRampTime
        lastRampTime = now
        
        gain = gain.ramped(toward: targetGain, dt: dt, tauMs: gainRampMs)
        rate = rate.ramped(toward: targetRate, dt: dt, tauMs: rateRampMs)
        
        playerNode.volume = Float(gain * 2.0)
        varispeed.rate = Float(rate)
    }
}
