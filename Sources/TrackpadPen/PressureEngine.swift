import AppKit
import CoreGraphics
import Combine

/// Turns Force Touch trackpad force into tablet-style pen pressure for every app.
///
/// How it works:
///  1. `MultitouchReader` streams per-finger force (≈ grams) from the private
///     MultitouchSupport framework at ~100 Hz — the same source TrackWeight uses.
///  2. A session-level `CGEventTap` (after WindowServer has moved the cursor, before apps
///     see the event) rewrites every left mouse down / drag / up into a *tablet point*
///     subtype event carrying that force, normalised to 0…1, in `kCGMouseEventPressure`
///     and `kCGTabletEventPointPressure`.
///  3. A tablet *proximity enter* event is posted before each stroke and *proximity exit*
///     after it, which is what makes Photoshop / Affinity / Blender treat the input as a pen.
///  4. Optionally, Force Touch's own stage-2 "force click" events are swallowed so they
///     can't trigger Look Up / Quick Look mid-stroke.
final class PressureEngine: ObservableObject {

    // MARK: - Settings (persisted via UserDefaults)

    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: "enabled") {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "enabled"); isEnabled ? start() : stop() }
    }
    /// Swallow the system's force-click (stage 2) events while enabled.
    @Published var suppressForceClick: Bool = UserDefaults.standard.object(forKey: "suppressForceClick") as? Bool ?? true {
        didSet { UserDefaults.standard.set(suppressForceClick, forKey: "suppressForceClick") }
    }
    /// Hardware-level: tell the trackpad to stop responding to force entirely while enabled.
    /// Experimental — on some firmware this disables *all* clicking. Always restored on stop/quit.
    @Published var hardwareForceOff: Bool = UserDefaults.standard.bool(forKey: "hardwareForceOff") {
        didSet {
            UserDefaults.standard.set(hardwareForceOff, forKey: "hardwareForceOff")
            if isRunning { applyHardwareForce() }
        }
    }
    /// Force (grams) that maps to full pressure.
    @Published var maxForce: Double = UserDefaults.standard.object(forKey: "maxForce") as? Double ?? 200 {
        didSet { UserDefaults.standard.set(maxForce, forKey: "maxForce") }
    }
    /// Force (grams) below which pressure is zero. Lets a resting finger register as 0.
    @Published var deadzone: Double = UserDefaults.standard.object(forKey: "deadzone") as? Double ?? 15 {
        didSet { UserDefaults.standard.set(deadzone, forKey: "deadzone") }
    }
    /// Gamma applied to normalised pressure. <1 heavier light touches, >1 lighter.
    @Published var gamma: Double = UserDefaults.standard.object(forKey: "gamma") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(gamma, forKey: "gamma") }
    }
    /// Pressure floor while the button is down, so the first dab of a stroke is visible.
    @Published var minPressure: Double = UserDefaults.standard.object(forKey: "minPressure") as? Double ?? 0.05 {
        didSet { UserDefaults.standard.set(minPressure, forKey: "minPressure") }
    }

    // MARK: - Live state for the UI

    @Published private(set) var livePressure: Double = 0
    @Published private(set) var liveGrams: Double = 0
    @Published private(set) var liveTouches: Int = 0
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var diagnostics = ""

    // MARK: - Internals

    private let reader = MultitouchReader()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var thread: Thread?

    private var inStroke = false
    private var lastUIPublish = Date.distantPast
    private var frameCount = 0
    private var mouseEventCount = 0
    private let counterLock = NSLock()

    private let eventSource = CGEventSource(stateID: .hidSystemState)

    /// Identity we present to apps. Arbitrary but stable.
    private let deviceID: Int64 = 0x5450          // "TP"
    private let vendorID: Int64 = 0x5450
    private let tabletID: Int64 = 1
    private let pointerID: Int64 = 1
    private let uniqueID: Int64 = 0x5450_5045_4E00  // "TPPEN"
    private let pointerTypePen: Int64 = 1           // NSPointingDeviceType.pen
    /// Capability mask bits (IOHIDFamily transducer caps): deviceID|absX|absY|buttons|pressure
    private let capabilityMask: Int64 = 0x1 | 0x2 | 0x4 | 0x40 | 0x400

    private static let pressureEventType = CGEventType(rawValue: 34)! // NSEventTypePressure

    init() {
        reader.onFrame = { [weak self] frame in self?.handleFrame(frame) }
        if !reader.isAvailable {
            statusMessage = reader.lastError ?? "MultitouchSupport unavailable"
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard tap == nil else { return }
        guard reader.isAvailable else {
            statusMessage = reader.lastError ?? "MultitouchSupport unavailable"
            DispatchQueue.main.async { self.isEnabled = false }
            return
        }
        guard Permissions.ensure() else {
            statusMessage = "Needs Accessibility + Input Monitoring"
            DispatchQueue.main.async { self.isEnabled = false }
            return
        }
        guard reader.startStreaming() else {
            statusMessage = reader.lastError ?? "Could not open trackpad"
            DispatchQueue.main.async { self.isEnabled = false }
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << Self.pressureEventType.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: PressureEngine.tapCallback,
            userInfo: refcon
        ) else {
            statusMessage = "Failed to create event tap"
            reader.stopStreaming()
            DispatchQueue.main.async { self.isEnabled = false }
            return
        }

        self.tap = tap
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "TrackpadPen.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread

        isRunning = true
        statusMessage = reader.supportsForce ? "Running" : "Running (trackpad reports no force support)"
        applyHardwareForce()
    }

    func stop() {
        if inStroke { postProximity(enter: false); inStroke = false }
        reader.setSystemForceResponse(enabled: true)   // never leave the trackpad dead
        reader.stopStreaming()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopSourceInvalidate(runLoopSource) }
        if let tapRunLoop { CFRunLoopStop(tapRunLoop) }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        thread = nil
        isRunning = false
        livePressure = 0
        liveGrams = 0
        liveTouches = 0
        statusMessage = "Idle"
    }

    private func applyHardwareForce() {
        reader.setSystemForceResponse(enabled: !hardwareForceOff)
    }

    // MARK: - Multitouch frames

    private func handleFrame(_ frame: MultitouchReader.Frame) {
        counterLock.withLock { frameCount += 1 }
        publishLive(grams: Double(frame.force), touches: frame.touchCount)
    }

    /// Current 0…1 pressure from the latest multitouch frame, with curve applied.
    private func normalised(grams: Double) -> Double {
        let span = max(maxForce - deadzone, 1)
        var p = (grams - deadzone) / span
        p = min(max(p, 0), 1)
        if gamma != 1 { p = pow(p, gamma) }
        return p
    }

    private func currentPressure() -> Double {
        max(normalised(grams: Double(reader.current.force)), minPressure)
    }

    // MARK: - Tap callback

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<PressureEngine>.fromOpaque(refcon).takeUnretainedValue()
        return engine.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case Self.pressureEventType:
            // Force Touch's own stage events. Swallowing them hides force-click from apps.
            return suppressForceClick ? nil : Unmanaged.passUnretained(event)

        case .leftMouseDown:
            counterLock.withLock { mouseEventCount += 1 }
            if !inStroke { postProximity(enter: true); inStroke = true }
            stamp(event, buttons: 1)
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged:
            counterLock.withLock { mouseEventCount += 1 }
            stamp(event, buttons: 1)
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            stamp(event, buttons: 0, forcePressure: 0)
            if inStroke {
                inStroke = false
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in
                    self?.postProximity(enter: false)
                }
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Event synthesis

    /// Rewrite a mouse event into a tablet-point event carrying the current pressure.
    private func stamp(_ event: CGEvent, buttons: Int64, forcePressure: Double? = nil) {
        let p = forcePressure ?? currentPressure()
        let loc = event.location

        event.setIntegerValueField(.mouseEventSubtype, value: 1) // kCGEventMouseSubtypeTabletPoint
        event.setDoubleValueField(.mouseEventPressure, value: p)
        event.setDoubleValueField(.tabletEventPointPressure, value: p)
        event.setIntegerValueField(.tabletEventPointX, value: Int64(loc.x))
        event.setIntegerValueField(.tabletEventPointY, value: Int64(loc.y))
        event.setIntegerValueField(.tabletEventPointZ, value: 0)
        event.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        event.setDoubleValueField(.tabletEventTiltX, value: 0)
        event.setDoubleValueField(.tabletEventTiltY, value: 0)
        event.setDoubleValueField(.tabletEventRotation, value: 0)
        event.setDoubleValueField(.tabletEventTangentialPressure, value: 0)
        event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
    }

    /// Announce the (virtual) pen entering or leaving the tablet surface.
    private func postProximity(enter: Bool) {
        guard let e = CGEvent(source: eventSource) else { return }
        e.type = .tabletProximity
        e.location = NSEvent.mouseLocation.flippedForCG()
        e.setIntegerValueField(.tabletProximityEventVendorID, value: vendorID)
        e.setIntegerValueField(.tabletProximityEventTabletID, value: tabletID)
        e.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: pointerTypePen)
        e.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        e.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: uniqueID)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: pointerTypePen)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        // Session level so WindowServer never interprets it as a real tablet.
        e.post(tap: .cgSessionEventTap)
    }

    // MARK: - UI publishing (throttled to ~60 Hz)

    private func publishLive(grams: Double, touches: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastUIPublish) > 1.0 / 60 || touches == 0 else { return }
        lastUIPublish = now
        let pressure = normalised(grams: grams)
        let (frames, mouse) = counterLock.withLock { (frameCount, mouseEventCount) }
        DispatchQueue.main.async {
            self.liveGrams = grams
            self.liveTouches = touches
            self.livePressure = pressure
            self.diagnostics = "mt frames \(frames) · mouse evts \(mouse)"
        }
    }
}

private extension CGPoint {
    /// NSEvent.mouseLocation is bottom-left origin; CGEvent wants top-left origin.
    func flippedForCG() -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: x, y: h - y)
    }
}
