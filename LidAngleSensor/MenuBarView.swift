//
//  MenuBarView.swift
//  LidAngleSensor
//
//  Created by Sam on 2026-03-22.
//

import SwiftUI

struct MenuBarView: View {
    @Environment(\.lidAngleSensor) private var sensor
    @Environment(\.audioController) private var audioController
    @Environment(\.lidCloseEffect) private var closeEffect
    
    var body: some View {
        @Bindable var controller = audioController
        @Bindable var effect = closeEffect
        
        if !sensor.isAvailable {
            Text("Sensor Not Available")
        }
        
        Section {
            Picker("Sound Mode", selection: $controller.mode) {
                ForEach(AudioMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)
            
            Button(audioController.isPlaying ? "Stop" : "Start") {
                audioController.toggle()
            }
            .disabled(!audioController.canPlay && !audioController.isPlaying)
        }

        Section {
            Button(audioController.recorder.isRecording ? "Stop Recording" : "Record Custom Sound…") {
                audioController.toggleRecording()
            }
        }
        .disabled(!sensor.isAvailable)
        
        Section {
            Toggle("Close Animation", isOn: $effect.isEnabled)
            Button("Preview Close Animation") {
                closeEffect.preview()
            }
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
