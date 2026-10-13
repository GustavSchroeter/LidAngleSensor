//
//  ContentView.swift
//  LidAngleSensor
//
//  Created by Sam on 2026-03-22.
//

import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @Environment(\.lidAngleSensor) private var sensor
    @Environment(\.audioController) private var audioController
    @Environment(\.lidCloseEffect) private var closeEffect

    @State private var inspectorShown = true

    var body: some View {
        @Bindable var controller = audioController
        @Bindable var theremin = audioController.thereminEngine

        NavigationStack {
            VStack {
                if sensor.isAvailable {
                    Text("\(sensor.angle, format: .number)°")
                        .foregroundStyle(.blue)
                        .font(.system(size: 144, weight: .thin))
                        .tracking(-3)

                    Group {
                        Text("Velocity: \(String(format: "%02d", Int(sensor.velocity.rounded()))) deg/s")
                        Text(sensor.status)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("Not Available")
                        .foregroundStyle(.red)
                        .font(.system(size: 56, weight: .light))

                    Text(sensor.status)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                        .padding(.top, 4)
                }
            }
            .monospacedDigit()
            .onAppear {
                sensor.start()
            }
            .onChange(of: sensor.tick) {
                audioController.feed(angle: sensor.angle, velocity: sensor.velocity)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button(
                        audioController.isPlaying ? "Stop" : "Play",
                        systemImage: audioController.isPlaying ? "stop" : "play"
                    ) {
                        audioController.toggle()
                    }
                    .symbolVariant(.fill)
                    .disabled(!sensor.isAvailable || !audioController.canPlay)
                    .keyboardShortcut(.space, modifiers: [])

                    Button {
                        inspectorShown.toggle()
                    } label: {
                        Label("Audio Controls", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .inspector(isPresented: $inspectorShown) {
                Form {
                    Section {
                        Picker("Audio Mode", selection: $controller.mode) {
                            ForEach(AudioMode.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }

                        switch audioController.mode {
                        case .creak:
                            LabeledContent("Gain", value: audioController.creakEngine.gain, format: .number.precision(.fractionLength(2)))
                            LabeledContent("Rate", value: audioController.creakEngine.rate, format: .number.precision(.fractionLength(2)))
                        case .theremin:
                            LabeledContent("Frequency", value: audioController.thereminEngine.frequency, format: .number.precision(.fractionLength(1)))
                            LabeledContent("Volume", value: audioController.thereminEngine.volume, format: .number.precision(.fractionLength(2)))
                        case .custom:
                            LabeledContent("Gain", value: audioController.customEngine.gain, format: .number.precision(.fractionLength(2)))
                            LabeledContent("Rate", value: audioController.customEngine.rate, format: .number.precision(.fractionLength(2)))
                        }
                    }

                    switch audioController.mode {
                    case .creak:
                        CreakParameterSections(engine: audioController.creakEngine)
                    case .theremin:
                        Section("Frequency") {
                            ParameterSlider(label: "Min", value: $theremin.minFrequency, range: 55...880, unit: "Hz", fractionDigits: 0)
                            ParameterSlider(label: "Max", value: $theremin.maxFrequency, range: 110...2000, unit: "Hz", fractionDigits: 0)
                        }
                        Section("Volume") {
                            ParameterSlider(label: "Base", value: $theremin.baseVolume, range: 0...1, fractionDigits: 2)
                            ParameterSlider(label: "Velocity Boost", value: $theremin.velocityVolumeBoost, range: 0...1, fractionDigits: 2)
                        }
                        Section("Vibrato") {
                            ParameterSlider(label: "Rate", value: $theremin.vibratoFreq, range: 0...20, unit: "Hz", fractionDigits: 1)
                            ParameterSlider(label: "Depth", value: $theremin.vibratoDepth, range: 0...0.15, fractionDigits: 3)
                        }
                        Section("Ramping") {
                            ParameterSlider(label: "Frequency", value: $theremin.frequencyRampMs, range: 5...300, unit: "ms", fractionDigits: 0)
                            ParameterSlider(label: "Volume", value: $theremin.volumeRampMs, range: 5...300, unit: "ms", fractionDigits: 0)
                        }
                    case .custom:
                        RecordingSection()
                        if audioController.customEngine.hasSound {
                            CreakParameterSections(engine: audioController.customEngine)
                        }
                    }

                    Section {
                        Button("Reset to Defaults") {
                            audioController.activeEngine.resetToDefaults()
                        }
                    }

                    CloseEffectSection()
                }
                .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
                .disabled(!sensor.isAvailable)
            }
        }
        .frame(minWidth: 800, minHeight: 400)
        .frame(idealWidth: 900, idealHeight: 667)
    }
}

// MARK: - Creak-style parameters (shared by Creak and Custom)

private struct CreakParameterSections: View {
    @Bindable var engine: CreakAudioEngine

    var body: some View {
        Section("Velocity") {
            ParameterSlider(label: "Full Volume", value: $engine.velocityFull, range: 1...100, unit: "deg/s", fractionDigits: 0)
            ParameterSlider(label: "Quiet", value: $engine.velocityQuiet, range: 10...300, unit: "deg/s", fractionDigits: 0)
        }
        Section("Pitch") {
            ParameterSlider(label: "Min Rate", value: $engine.minRate, range: 0.5...1.0, unit: "×", fractionDigits: 2)
            ParameterSlider(label: "Max Rate", value: $engine.maxRate, range: 1.0...2.0, unit: "×", fractionDigits: 2)
        }
        Section("Ramping") {
            ParameterSlider(label: "Gain", value: $engine.gainRampMs, range: 10...500, unit: "ms", fractionDigits: 0)
            ParameterSlider(label: "Rate", value: $engine.rateRampMs, range: 10...500, unit: "ms", fractionDigits: 0)
        }
    }
}

// MARK: - Lid close animation

private struct CloseEffectSection: View {
    @Environment(\.lidCloseEffect) private var closeEffect

    var body: some View {
        @Bindable var effect = closeEffect

        Section("Close Animation") {
            Toggle("Animate when closing the lid", isOn: $effect.isEnabled)

            if !closeEffect.hasScreenPermission {
                Text("Needs Screen Recording permission to take a snapshot of the screen. The snapshot stays in memory and is never saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Grant Screen Recording…") {
                    closeEffect.requestPermission()
                }
            }

            ParameterSlider(label: "Tilt", value: $effect.tiltStrength, range: 0.2...1.0, unit: "×", fractionDigits: 2)
            ParameterSlider(label: "Blur", value: $effect.blurAmount, range: 0...40, unit: "pt", fractionDigits: 0)
            ParameterSlider(label: "Darken", value: $effect.dimAmount, range: 0...1, fractionDigits: 2)

            HStack {
                Button("Preview") {
                    closeEffect.preview()
                }
                Spacer()
                Button("Defaults") {
                    closeEffect.resetToDefaults()
                }
            }

            if let error = closeEffect.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            closeEffect.refreshPermission()
        }
    }
}

// MARK: - Microphone recording

private struct RecordingSection: View {
    @Environment(\.audioController) private var audioController

    var body: some View {
        let recorder = audioController.recorder

        Section("Your Sound") {
            Button {
                audioController.toggleRecording()
            } label: {
                Label(
                    recorder.isRecording ? "Stop Recording" : (audioController.customEngine.hasSound ? "Record Again" : "Record with Microphone"),
                    systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.fill"
                )
                .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
            }
            .keyboardShortcut("r", modifiers: [.command])

            if recorder.isRecording {
                ProgressView(value: recorder.level)
                    .tint(.red)
                LabeledContent(
                    "Recording",
                    value: "\(recorder.elapsed.formatted(.number.precision(.fractionLength(1)))) / \(Int(SoundRecorder.maxDuration)) s"
                )
                .monospacedDigit()
            } else if audioController.customEngine.hasSound {
                Text("Sound saved. Press Play, then move the lid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete Sound", role: .destructive) {
                    audioController.deleteCustomSound()
                }
            } else {
                Text("Record a short sound (max. \(Int(SoundRecorder.maxDuration)) s). Silence at the start and end is trimmed automatically, and the sound loops while the lid moves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = recorder.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    ContentView()
}
