import AppKit

class ImageAspectFillView: NSImageView {
    override var image: NSImage? {
        set {
            layer = CALayer()
            layer?.contentsGravity = .resizeAspectFill
            layer?.contents = newValue
            wantsLayer = true
            super.image = newValue
        }

        get {
            return super.image
        }
    }
}
