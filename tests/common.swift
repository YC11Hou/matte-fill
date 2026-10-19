import Cocoa
import Metal

// Shared helpers for the offline checks (tests/run.sh compiles them with src/main.swift minus its entry code).

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   " : "  FAIL ", what)
    if !ok { failures += 1 }
}

let dev = MTLCreateSystemDefaultDevice()!, queue = dev.makeCommandQueue()!

final class Target {
    let w: Int, h: Int, tex: MTLTexture, r: CARenderer
    init(_ layer: CALayer, w: Int, h: Int) {
        self.w = w; self.h = h
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead, .shaderWrite]; td.storageMode = .shared
        tex = dev.makeTexture(descriptor: td)!
        r = CARenderer(mtlTexture: tex, options: [kCARendererMetalCommandQueue: queue])
        layer.frame = CGRect(x: 0, y: 0, width: w, height: h)
        r.layer = layer; r.bounds = layer.frame
    }
    // Renders a fresh frame and returns a pixel reader in view coordinates (flipped: y down).
    func render() -> (Int, Int) -> (Int, Int, Int) {
        CATransaction.flush()
        let zeros = [UInt8](repeating: 0, count: w * h * 4)
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: zeros, bytesPerRow: w * 4)
        r.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil); r.addUpdate(r.bounds); r.render(); r.endFrame()
        let cb = queue.makeCommandBuffer()!; cb.commit(); cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&out, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let (w, h) = (self.w, self.h)
        return { x, y in let o = ((h - 1 - y) * w + x) * 4; return (Int(out[o + 2]), Int(out[o + 1]), Int(out[o])) }
    }
}

// A capture-like frame: gray level per pixel from `f`.
func frame(_ w: Int, _ h: Int, _ f: (Int, Int) -> Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let st = CVPixelBufferGetBytesPerRow(pb!), p = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h { for x in 0..<w { let o = y * st + x * 4, c = UInt8(f(x, y)); p[o] = c; p[o + 1] = c; p[o + 2] = c; p[o + 3] = 255 } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tol: Int = 1) -> Bool {
    abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol && abs(a.2 - b.2) <= tol
}

// Every sampled pixel of a region equals `c` (no black, no leftovers).
func uniform(_ px: (Int, Int) -> (Int, Int, Int), _ xs: Range<Int>, _ ys: Range<Int>, _ c: (Int, Int, Int)) -> Bool {
    for y in Swift.stride(from: ys.lowerBound, to: ys.upperBound, by: 2) {
        for x in Swift.stride(from: xs.lowerBound, to: xs.upperBound, by: 3) where !near(px(x, y), c) { return false }
    }
    return true
}

