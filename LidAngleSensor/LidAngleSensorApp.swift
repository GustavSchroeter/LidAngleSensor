//
//  LidAngleSensorApp.swift
//  LidAngleSensor
//
//  Created by Sam on 2026-03-22.
//

import SwiftUI

@main
struct LidAngleSensorApp: App {
    @State private var sensor = LidAngleSensor()
    @State private var audioController = AudioController()
    @State private var closeEffect = LidCloseEffect()
    
    var body: some Scene {
        Window("Lid Angle Sensor", id: "main") {
            ContentView()
                .environment(\.lidAngleSensor, sensor)
                .environment(\.audioController, audioController)
                .environment(\.lidCloseEffect, closeEffect)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    closeEffect.attach(to: sensor)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Link(destination: URL(string: "https://github.com/samhenrigold/LidAngleSensor")!) {
                    Label("View Source", systemImage: "swift")
                }
            }
        }
        
        MenuBarExtra {
            MenuBarView()
                .environment(\.lidAngleSensor, sensor)
                .environment(\.audioController, audioController)
                .environment(\.lidCloseEffect, closeEffect)
        } label: {
            Image(systemName: "angle")
            
            if sensor.isAvailable {
                Text("\(sensor.angle, format: .number.precision(.fractionLength(0)))°")
                    .monospacedDigit()
            }
        }
    }
}
