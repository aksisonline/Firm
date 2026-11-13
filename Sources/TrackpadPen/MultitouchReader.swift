import Foundation
import MultitouchShim

/// Streams per-finger force from the Force Touch trackpad via the private
/// MultitouchSupport.framework — the same source TrackWeight uses.
///
/// Unlike `NSEvent.pressure`, this reports force for *any* finger contact, not only while
/// the click is engaged, and the value is roughly in grams.
final class MultitouchReader {

    struct Frame {
        var force: Float = 0        // strongest touch, grams-ish
        var touchCount: Int = 0
        var timestamp: Double = 0
    }

    private(set) var isAvailable = false
    private(set) var supportsForce = false
    private(set) var lastError: String?

    private var device: MTDeviceRef?
    private var running = false
    private let lock = NSLock()
    private var latest = Frame()

    /// Called on the multitouch thread for every frame (~100 Hz). Keep it cheap.
    var onFrame: ((Frame) -> Void)?

    // dlsym'd entry points
    private var createDefault: MTDeviceCreateDefault_f?
    private var release: MTDeviceRelease_f?
    private var start: MTDeviceStart_f?
    private var stop: MTDeviceStop_f?
    private var supportsForceFn: MTDeviceSupportsForce_f?
    private var registerFrameCallback: MTRegisterContactFrameCallbackWithRefcon_f?
    private var getForceResponse: MTDeviceGetSystemForceResponseEnabled_f?
    private var setForceResponse: MTDeviceSetSystemForceResponseEnabled_f?

    init() {
        load()
    }

    deinit { stopStreaming() }

    // MARK: - Loading

    private func load() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            lastError = "dlopen failed: \(String(cString: dlerror()))"
            return
        }
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        createDefault = sym("MTDeviceCreateDefault", as: MTDeviceCreateDefault_f.self)
        release = sym("MTDeviceRelease", as: MTDeviceRelease_f.self)
        start = sym("MTDeviceStart", as: MTDeviceStart_f.self)
        stop = sym("MTDeviceStop", as: MTDeviceStop_f.self)
        supportsForceFn = sym("MTDeviceSupportsForce", as: MTDeviceSupportsForce_f.self)
        registerFrameCallback = sym("MTRegisterContactFrameCallbackWithRefcon", as: MTRegisterContactFrameCallbackWithRefcon_f.self)
        getForceResponse = sym("MTDeviceGetSystemForceResponseEnabled", as: MTDeviceGetSystemForceResponseEnabled_f.self)
        setForceResponse = sym("MTDeviceSetSystemForceResponseEnabled", as: MTDeviceSetSystemForceResponseEnabled_f.self)

        guard createDefault != nil, start != nil, stop != nil, registerFrameCallback != nil else {
            lastError = "MultitouchSupport symbols missing"
            return
        }
        isAvailable = true
    }

    // MARK: - Streaming

    @discardableResult
    func startStreaming() -> Bool {
        guard isAvailable, !running else { return running }
        guard let dev = createDefault?() else {
            lastError = "No multitouch device found"
            return false
        }
        device = dev
        supportsForce = supportsForceFn?(dev) ?? false

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = registerFrameCallback?(dev, MultitouchReader.frameCallback, refcon)
        let status = start?(dev, MTRunModeLessVerbose) ?? -1
        guard status == 0 else {
            lastError = "MTDeviceStart failed (\(status))"
            release?(dev)
            device = nil
            return false
        }
        running = true
        return true
    }

    func stopStreaming() {
        guard running, let dev = device else { return }
        _ = stop?(dev)
        release?(dev)
        device = nil
        running = false
        lock.withLock { latest = Frame() }
    }

    var current: Frame { lock.withLock { latest } }

    // MARK: - Force-click control

    /// Whether the trackpad currently responds to force (click / force-click) at the hardware level.
    var systemForceResponseEnabled: Bool? {
        guard let dev = device, let get = getForceResponse else { return nil }
        return get(dev)
    }

    /// Toggle the trackpad's built-in force response. Note: on some firmware this disables
    /// *all* clicks, not only force-click — always restore before exit.
    @discardableResult
    func setSystemForceResponse(enabled: Bool) -> Bool {
        guard let dev = device, let set = setForceResponse else { return false }
        set(dev, enabled)
        return true
    }

    // MARK: - Callback

    private static let frameCallback: MTFrameCallbackWithRefcon = { _, touches, count, timestamp, _, refcon in
        guard let refcon else { return }
        let reader = Unmanaged<MultitouchReader>.fromOpaque(refcon).takeUnretainedValue()
        var frame = Frame(force: 0, touchCount: Int(count), timestamp: timestamp)
        if let touches, count > 0 {
            for i in 0..<Int(count) {
                let t = touches[i]
                // Only fingers actually on the surface contribute.
                if t.state == MTTouchStateTouching || t.state == MTTouchStateMakeTouch {
                    frame.force = max(frame.force, t.pressure)
                }
            }
        }
        reader.lock.withLock { reader.latest = frame }
        reader.onFrame?(frame)
    }
}
