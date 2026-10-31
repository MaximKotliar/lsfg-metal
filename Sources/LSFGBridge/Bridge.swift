import Foundation
import LSFGCore
import Metal

// C API for the CrossOver hook (lsfghook.so, Objective-C, x86_64 under Rosetta).
// Built as liblsfgbridge.dylib and dlopen()ed by the hook. Metal objects cross the
// boundary as unretained opaque pointers; the hook keeps them alive.

private final class Context: @unchecked Sendable {
    let lock = NSLock()
    var lsfg: LSFG31

    init(lsfg: LSFG31) { self.lsfg = lsfg }
}

private func object<T>(_ p: UnsafeRawPointer, as: T.Type) -> T {
    Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as! T
}

private func opaque(_ o: AnyObject) -> UnsafeRawPointer {
    UnsafeRawPointer(Unmanaged.passUnretained(o).toOpaque())
}

private func writeError(_ message: String, _ buffer: UnsafeMutablePointer<CChar>?, _ length: Int32) {
    guard let buffer, length > 0 else { return }
    let bytes = Array(message.utf8.prefix(Int(length) - 1))
    for (i, b) in bytes.enumerated() { buffer[i] = CChar(bitPattern: b) }
    buffer[bytes.count] = 0
}

/// Creates an LSFG 3.1 context on `device` for frames of the given size and pixel format.
/// Loads the translated kernels for the user's Lossless.dll (LSFG_DLL or the Steam install).
/// Building pipelines can take a while the first time: call this off the render thread.
@_cdecl("lsfg_bridge_create")
public func lsfg_bridge_create(_ device: UnsafeRawPointer, _ width: Int32, _ height: Int32, _ pixelFormat: UInt32,
                               _ multiplier: Int32, _ flowScale: Float, _ performance: Int32,
                               _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorLength: Int32) -> UnsafeMutableRawPointer? {
    do {
        let device = object(device, as: MTLDevice.self)
        let dll: URL
        if let path = ProcessInfo.processInfo.environment["LSFG_DLL"] {
            dll = URL(fileURLWithPath: path)
        } else if let install = LosslessLocator.findAll().first {
            dll = install.dll
        } else {
            writeError("Lossless.dll not found (Steam app 993090 in a CrossOver bottle)", errorBuffer, errorLength)
            return nil
        }
        var settings = LSFGSettings()
        settings.multiplier = Int(max(2, min(8, multiplier)))
        settings.flowScale = max(0.25, min(1, flowScale))
        settings.performance = performance != 0
        guard let format = MTLPixelFormat(rawValue: UInt(pixelFormat)) else {
            writeError("unknown pixel format \(pixelFormat)", errorBuffer, errorLength)
            return nil
        }
        let kernels = try LSFGKernels(cacheDirectory: try LSFGKernels.cacheDirectory(forDLL: dll),
                                      ids: LSFG31Shaders.allIDs(fp16: settings.fp16, performance: settings.performance),
                                      device: device)
        let lsfg = try LSFG31(width: Int(width), height: Int(height), format: format, settings: settings, kernels: kernels)
        return Unmanaged.passRetained(Context(lsfg: lsfg)).toOpaque()
    } catch {
        writeError("\(error)", errorBuffer, errorLength)
        return nil
    }
}

/// The texture the next real frame must be copied into before `lsfg_bridge_encode`.
@_cdecl("lsfg_bridge_input")
public func lsfg_bridge_input(_ ctx: UnsafeMutableRawPointer) -> UnsafeRawPointer {
    let c = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
    c.lock.lock(); defer { c.lock.unlock() }
    return opaque(c.lsfg.nextInput)
}

/// Encodes LSFG for the real frame just copied into the input, into `commandBuffer`.
/// Returns how many generated frames (outputs 0..n-1) are valid: 0 while history fills up.
@_cdecl("lsfg_bridge_encode")
public func lsfg_bridge_encode(_ ctx: UnsafeMutableRawPointer, _ commandBuffer: UnsafeRawPointer) -> Int32 {
    let c = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
    c.lock.lock(); defer { c.lock.unlock() }
    let warm = c.lsfg.frameIndex >= 2
    do {
        try c.lsfg.encode(into: object(commandBuffer, as: MTLCommandBuffer.self), generate: warm)
    } catch {
        return -1
    }
    return warm ? Int32(c.lsfg.outputs.count) : 0
}

/// Generated frame `index` (earliest first) from the last encode.
@_cdecl("lsfg_bridge_output")
public func lsfg_bridge_output(_ ctx: UnsafeMutableRawPointer, _ index: Int32) -> UnsafeRawPointer {
    let c = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
    c.lock.lock(); defer { c.lock.unlock() }
    return opaque(c.lsfg.outputs[Int(index)])
}

@_cdecl("lsfg_bridge_destroy")
public func lsfg_bridge_destroy(_ ctx: UnsafeMutableRawPointer) {
    Unmanaged<Context>.fromOpaque(ctx).release()
}
