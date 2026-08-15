import Cocoa

/// A reusable offscreen bitmap for phosphor-style views. The buffer persists across frames until
/// its pixel dimensions change, allowing each new frame to decay and paint over the previous one.
struct PhosphorBuffer {
    private var context: CGContext?
    private var pxW = 0
    private var pxH = 0

    mutating func ensure(bounds: NSRect, scale: CGFloat) -> CGContext? {
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }
        if context == nil || width != pxW || height != pxH {
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: scale, y: scale)  // draw in point coordinates
            context = ctx
            pxW = width
            pxH = height
        }
        return context
    }

    static func decayFill(_ context: CGContext, alpha: CGFloat, in rect: CGRect) {
        context.setBlendMode(.destinationOut)
        context.setFillColor(NSColor(white: 0, alpha: alpha).cgColor)
        context.fill(rect)
        context.setBlendMode(.normal)
    }
}
