import AppKit
import SwiftUI

final class AXDumpViewer: NSScrollView {
    let textView = NSTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.layoutManager?.allowsNonContiguousLayout = true

        documentView = textView
    }

    required init?(coder: NSCoder) {
        nil
    }

    func display(_ contents: String) {
        guard textView.string != contents else { return }
        textView.string = contents
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

struct AXDumpTextView: NSViewRepresentable {
    let contents: String

    func makeNSView(context: Context) -> AXDumpViewer {
        AXDumpViewer()
    }

    func updateNSView(_ viewer: AXDumpViewer, context: Context) {
        viewer.display(contents)
    }
}
