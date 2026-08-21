import AppKit

// MARK: - Image store (~/.floatnote-images/)
//
// One PNG per inserted image, named <UUID>.png — same one-dir-of-files pattern
// as recordings and Excalidraw boards. The note's persisted HTML never contains
// the image: it carries a plain-text marker ⟦img:<uuid>:<width>⟧ instead,
// because the Cocoa HTML exporter drops NSTextAttachment images but round-trips
// plain text byte-for-byte. Markers are swapped for live ImageAttachments on
// load and back to markers on save (always on a COPY of the text storage).

enum ImageStore {
    static let dirPath = NSHomeDirectory() + "/.floatnote-images"

    static func url(for id: String) -> URL {
        URL(fileURLWithPath: dirPath).appendingPathComponent(id + ".png")
    }

    /// Normalize any NSImage to PNG and write it atomically. Returns the new id.
    static func savePNG(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            dbg("ImageStore.savePNG: could not encode image")
            return nil
        }
        let id = UUID().uuidString
        do {
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            let tmp = URL(fileURLWithPath: dirPath).appendingPathComponent(".tmp-" + id)
            try png.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url(for: id), withItemAt: tmp)
            return id
        } catch {
            dbg("ImageStore.savePNG failed: \(error)")
            return nil
        }
    }

    static func load(id: String) -> NSImage? { NSImage(contentsOf: url(for: id)) }

    static func delete(id: String) { try? FileManager.default.removeItem(at: url(for: id)) }

    // MARK: Markers

    static let markerRegex = try! NSRegularExpression(
        pattern: "⟦img:([0-9A-Fa-f-]{36}):(\\d+)⟧")

    static func marker(id: String, width: CGFloat) -> String {
        "⟦img:\(id):\(Int(width.rounded()))⟧"
    }

    /// Image ids referenced by a note's HTML (hard-delete cascade).
    static func imageIds(inHTML html: String) -> [String] {
        let ns = html as NSString
        return markerRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    static func deleteImages(inHTML html: String) {
        for id in imageIds(inHTML: html) { delete(id: id) }
    }
}

/// Overlay decoration (image selection border, resize handle) that must never
/// swallow mouse events — the text view owns all hit-testing for image
/// selection and resizing, so these views stay transparent to the mouse.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Inline image attachment

/// A text attachment that knows its store id and display width, so the marker
/// round-trip can rebuild it and the resize handle can rescale it.
final class ImageAttachment: NSTextAttachment {
    let imageId: String
    private(set) var displayWidth: CGFloat
    private let aspect: CGFloat  // height / width

    init?(imageId: String, displayWidth: CGFloat) {
        guard let img = ImageStore.load(id: imageId), img.size.width > 0 else { return nil }
        self.imageId = imageId
        self.aspect = img.size.height / img.size.width
        self.displayWidth = max(1, displayWidth)
        super.init(data: nil, ofType: nil)
        self.image = img
        updateBounds()
    }

    required init?(coder: NSCoder) { nil }

    func setDisplayWidth(_ w: CGFloat) {
        displayWidth = max(1, w)
        updateBounds()
    }

    var displayHeight: CGFloat { (displayWidth * aspect).rounded() }

    /// Authoritative size hook: the layout manager asks the attachment itself,
    /// so a resized attachment reports its NEW size instead of a cached cell size.
    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: displayWidth.rounded(), height: displayHeight)
    }

    private func updateBounds() {
        bounds = CGRect(x: 0, y: 0, width: displayWidth.rounded(), height: displayHeight)
    }
}

// MARK: - Marker <-> attachment conversion

extension NSMutableAttributedString {
    /// Load path: swap persisted ⟦img:…⟧ markers for live ImageAttachments.
    /// A marker whose file is gone becomes dimmed literal text instead.
    func resolveImageMarkers(bodyFont: NSFont, bodyColor: NSColor) {
        let ns = string as NSString
        let matches = ImageStore.markerRegex.matches(
            in: string, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let id = ns.substring(with: m.range(at: 1))
            let width = CGFloat(Int(ns.substring(with: m.range(at: 2))) ?? 200)
            if let attachment = ImageAttachment(imageId: id, displayWidth: width) {
                replaceCharacters(in: m.range, with: NSAttributedString(attachment: attachment))
            } else {
                let missing = NSAttributedString(string: "⟨missing image⟩", attributes: [
                    .font: bodyFont,
                    .foregroundColor: bodyColor.withAlphaComponent(0.4)
                ])
                replaceCharacters(in: m.range, with: missing)
            }
        }
    }

    /// Save path: swap ImageAttachments for persistable plain-text markers.
    /// MUST run on a copy — never mutate the live text storage during save.
    func replaceImageAttachmentsWithMarkers(font: NSFont, color: NSColor) {
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length),
                           options: [.reverse]) { value, range, _ in
            guard let att = value as? ImageAttachment else { return }
            let text = NSAttributedString(
                string: ImageStore.marker(id: att.imageId, width: att.displayWidth),
                attributes: [.font: font, .foregroundColor: color])
            replaceCharacters(in: range, with: text)
        }
    }
}
