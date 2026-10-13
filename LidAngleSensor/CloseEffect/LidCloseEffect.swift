//
//  LidCloseEffect.swift
//  LidAngleSensor
//
//  Lid-close animation: when the lid starts closing, a snapshot of the
//  built-in display is shown full-screen and tilted / blurred according to the
//  lid angle, so the picture appears to stay upright while the display folds
//  down over it. Opening the lid again (or holding still) returns to normal.
//  Sleep behaviour is untouched.
//

import AppKit
import CoreImage
import QuartzCore
import SwiftUI
@preconcurrency import ScreenCaptureKit

extension EnvironmentValues {
    @Entry var lidCloseEffect: LidCloseEffect = .init()
}

@Observable
final class LidCloseEffect {

    // MARK: Settings (persisted)

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            updateRunning()
        }
    }

    /// How strongly the picture counter-tilts relative to the lid movement.
    var tiltStrength: Double {
        didSet { UserDefaults.standard.set(tiltStrength, forKey: Keys.tilt) }
    }

    /// Fall direction: -1 = topples to the left, 0 = falls straight back, +1 = topples to the right.
    var direction: Double {
        didSet { UserDefaults.standard.set(direction, forKey: Keys.direction) }
    }

    /// Maximum blur radius (points) reached while closing.
    var blurAmount: Double {
        didSet { UserDefaults.standard.set(blurAmount, forKey: Keys.blur) }
    }

    /// How much the picture darkens towards a fully closed lid (0...1).
    var dimAmount: Double {
        didSet { UserDefaults.standard.set(dimAmount, forKey: Keys.dim) }
    }

    // MARK: Published State

    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    private(set) var isShowing = false
    private(set) var lastError: String?

    // MARK: Private State

    private enum Keys {
        static let enabled = "closeEffect.enabled"
        static let tilt = "closeEffect.tilt"
        static let blur = "closeEffect.blur"
        static let dim = "closeEffect.dim"
        static let direction = "closeEffect.direction"
    }

    private enum Phase { case idle, capturing, showing, fading }

    @ObservationIgnored private weak var sensor: LidAngleSensor?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var overlay: CloseOverlayWindow?
    @ObservationIgnored private var cachedDisplay: SCDisplay?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    @ObservationIgnored private var phase = Phase.idle
    @ObservationIgnored private var restAngle = 0.0
    @ObservationIgnored private var lastAngle = -1.0
    @ObservationIgnored private var lastAngleChange: TimeInterval = 0
    @ObservationIgnored private var startAngle = 0.0
    @ObservationIgnored private var shownDelta = 0.0
    @ObservationIgnored private var fadeStart: TimeInterval = 0
    @ObservationIgnored private var previewStart: TimeInterval?
    @ObservationIgnored private var lastStep: TimeInterval = 0

    // Tuning
    private static let triggerDrop = 2.0            // degrees below rest angle that start the effect
    private static let restSettleTime = 0.6         // s of no movement before the rest angle is re-learned
    private static let holdTimeout = 1.5            // s of no movement while shown before fading out
    private static let fadeDuration = 0.18
    private static let frameInterval = 1.0 / 60.0
    private static let previewOpenAngle = 110.0
    private static let previewDuration = 2.4

    // MARK: Lifecycle

    init() {
        let d = UserDefaults.standard
        isEnabled = d.object(forKey: Keys.enabled) as? Bool ?? false
        tiltStrength = d.object(forKey: Keys.tilt) as? Double ?? 0.7
        blurAmount = d.object(forKey: Keys.blur) as? Double ?? 14
        dimAmount = d.object(forKey: Keys.dim) as? Double ?? 0.5
        direction = d.object(forKey: Keys.direction) as? Double ?? 0
    }

    /// Connects the effect to the sensor. Call once the real sensor exists.
    func attach(to sensor: LidAngleSensor) {
        self.sensor = sensor
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cachedDisplay = nil }
            }
        }
        updateRunning()
    }

    func resetToDefaults() {
        tiltStrength = 0.7
        direction = 0
        blurAmount = 14
        dimAmount = 0.5
    }

    // MARK: Permission

    func refreshPermission() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
    }

    func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        refreshPermission()
    }

    // MARK: Preview

    /// Plays a simulated close/open so the effect can be seen without moving the lid.
    func preview() {
        guard phase == .idle else { return }
        previewStart = nil
        startAngle = Self.previewOpenAngle
        startTimerIfNeeded()
        beginCapture(isPreview: true)
    }

    // MARK: Running

    private func updateRunning() {
        if isEnabled {
            refreshPermission()
            if activity == nil {
                // Keep polling while in the background (App Nap would throttle the
                // timers) but still allow the Mac to sleep normally.
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                    reason: "Lid close animation"
                )
            }
            restAngle = sensor?.angle ?? 0
            startTimerIfNeeded()
        } else {
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
            if phase == .showing { hide() }
            stopTimerIfIdle()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        lastStep = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopTimerIfIdle() {
        guard !isEnabled, phase == .idle, previewStart == nil else { return }
        timer?.invalidate()
        timer = nil
    }

    // MARK: State Machine

    private func step() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0.001, now - lastStep))
        lastStep = now

        let angle: Double
        if let previewStart {
            let t = now - previewStart
            if t >= Self.previewDuration {
                self.previewStart = nil
                hide()
                return
            }
            angle = Self.previewAngle(at: t)
        } else {
            guard isEnabled, let sensor, sensor.isAvailable else {
                if phase == .fading { advanceFade(now: now) }
                stopTimerIfIdle()
                return
            }
            angle = sensor.angle
        }

        if angle != lastAngle {
            lastAngle = angle
            lastAngleChange = now
        }

        switch phase {
        case .idle:
            if angle >= restAngle || now - lastAngleChange > Self.restSettleTime {
                restAngle = angle
            } else if restAngle - angle >= Self.triggerDrop, restAngle > 20, hasScreenPermission {
                startAngle = restAngle
                beginCapture(isPreview: false)
            }

        case .capturing:
            break

        case .showing:
            let target = max(0, startAngle - angle)
            shownDelta = shownDelta.ramped(toward: target, dt: dt, tauMs: 35)
            overlay?.apply(delta: shownDelta, tilt: tiltStrength, direction: direction, blur: blurAmount, dim: dimAmount)

            if previewStart == nil {
                let reopened = angle >= startAngle - 1
                let heldStill = now - lastAngleChange > Self.holdTimeout && angle > 10
                if reopened || heldStill { hide() }
            }

        case .fading:
            advanceFade(now: now)
        }
    }

    private static func previewAngle(at t: TimeInterval) -> Double {
        let open = previewOpenAngle
        let closed = 12.0
        func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        switch t {
        case ..<1.1: return open - (open - closed) * ease(t / 1.1)
        case ..<1.5: return closed
        default:     return closed + (open - closed) * ease(min(1, (t - 1.5) / 0.8))
        }
    }

    // MARK: Capture & Display

    private func beginCapture(isPreview: Bool) {
        phase = .capturing
        lastError = nil
        Task {
            let result = await captureBuiltInDisplay()
            guard phase == .capturing else { return }
            guard let result else {
                phase = .idle
                restAngle = lastAngle
                refreshPermission()
                stopTimerIfIdle()
                return
            }

            let window = overlay ?? CloseOverlayWindow()
            overlay = window
            shownDelta = 0
            window.present(image: result.image, on: result.screen)
            window.apply(delta: 0, tilt: tiltStrength, direction: direction, blur: blurAmount, dim: dimAmount)
            phase = .showing
            isShowing = true
            if isPreview {
                previewStart = CACurrentMediaTime()
            }
        }
    }

    private func hide() {
        guard phase == .showing else { return }
        phase = .fading
        fadeStart = CACurrentMediaTime()
    }

    private func advanceFade(now: TimeInterval) {
        let p = (now - fadeStart) / Self.fadeDuration
        if p >= 1 {
            overlay?.dismiss()
            phase = .idle
            isShowing = false
            restAngle = sensor?.angle ?? lastAngle
            stopTimerIfIdle()
        } else {
            overlay?.alphaValue = CGFloat(1 - p)
        }
    }

    private func captureBuiltInDisplay() async -> (image: CGImage, screen: NSScreen)? {
        guard let screen = Self.builtInScreen() ?? NSScreen.main,
              let displayID = screen.displayID else { return nil }

        do {
            if cachedDisplay?.displayID != displayID {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                cachedDisplay = content.displays.first { $0.displayID == displayID }
            }
            guard let display = cachedDisplay else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = true
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            hasScreenPermission = true
            return (image, screen)
        } catch {
            lastError = "Screen capture failed: \(error.localizedDescription)"
            return nil
        }
    }

    private static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

// MARK: - Overlay Window

final class CloseOverlayWindow: NSWindow {

    private let rootView = NSView()
    private let imageLayer = CALayer()
    private let dimLayer = CALayer()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        rootView.wantsLayer = true
        rootView.layerUsesCoreImageFilters = true
        rootView.layer?.backgroundColor = NSColor.black.cgColor
        contentView = rootView

        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0)   // hinge = bottom edge
        imageLayer.contentsGravity = .resize
        imageLayer.isOpaque = true
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            imageLayer.filters = [blur]
        }

        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        imageLayer.addSublayer(dimLayer)

        rootView.layer?.addSublayer(imageLayer)
    }

    func present(image: CGImage, on screen: NSScreen) {
        setFrame(screen.frame, display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        rootView.frame = bounds
        imageLayer.bounds = bounds
        imageLayer.position = CGPoint(x: bounds.midX, y: 0)
        imageLayer.contents = image
        imageLayer.contentsScale = screen.backingScaleFactor
        dimLayer.frame = bounds

        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / (bounds.height * 1.6)
        rootView.layer?.sublayerTransform = perspective
        CATransaction.commit()

        alphaValue = 1
        orderFrontRegardless()
    }

    /// - Parameter delta: degrees the lid has closed since the effect started.
    /// - Parameter direction: -1 (left) ... 0 (straight back) ... +1 (right).
    func apply(delta: Double, tilt: Double, direction: Double, blur: Double, dim: Double) {
        let degrees = min(75, delta * tilt)
        let blurProgress = min(1, delta / 45)
        let smooth = blurProgress * blurProgress * (3 - 2 * blurProgress)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let d = min(1, max(-1, direction))
        let radians = degrees * .pi / 180

        // Pivot: bottom-centre for a straight fall, moving to the bottom-left
        // corner (falls right) or bottom-right corner (falls left).
        let bounds = imageLayer.bounds
        let anchorX = 0.5 - 0.5 * d
        imageLayer.anchorPoint = CGPoint(x: anchorX, y: 0)
        imageLayer.position = CGPoint(x: bounds.width * anchorX, y: 0)

        // Straight part: top edge tips away around the bottom hinge.
        let back = CATransform3DMakeRotation(-radians * (1 - abs(d)), 1, 0, 0)
        // Sideways part: far edge swings away around the vertical pivot edge…
        let side = CATransform3DMakeRotation(radians * d, 0, 1, 0)
        // …with a slight roll so it looks like it is toppling over.
        let roll = CATransform3DMakeRotation(-radians * d * 0.25, 0, 0, 1)

        imageLayer.transform = CATransform3DConcat(CATransform3DConcat(back, side), roll)
        imageLayer.setValue(blur * smooth, forKeyPath: "filters.blur.inputRadius")
        dimLayer.opacity = Float(dim * min(1, delta / 90))
        CATransaction.commit()
    }

    func dismiss() {
        orderOut(nil)
        imageLayer.contents = nil
        alphaValue = 1
    }
}
