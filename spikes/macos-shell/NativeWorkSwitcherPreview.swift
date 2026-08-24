import AppKit
import Foundation

final class NativeWorkSwitcherPreviewView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Preview")
    private let detailLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(item: NativeWorkItem?, boundedText: String?, loading: Bool = false) {
        guard let item else {
            titleLabel.stringValue = "Preview"
            detailLabel.stringValue = ""
            textView.string = ""
            emptyLabel.stringValue = "Select a pane to preview its current screen"
            emptyLabel.isHidden = false
            return
        }
        titleLabel.stringValue = item.headline
        detailLabel.stringValue = item.detail
        textView.string = boundedText ?? ""
        emptyLabel.stringValue = loading ? "Loading preview…" : "No visible text in this pane"
        emptyLabel.isHidden = boundedText != nil
        textView.scrollToEndOfDocument(nil)
        setAccessibilityLabel("Preview of \(item.headline)")
    }

    private func configure() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1

        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.borderType = .lineBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2

        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(scrollView)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(
                lessThanOrEqualTo: scrollView.widthAnchor, constant: -24),
        ])
        update(item: nil, boundedText: nil)
    }
}

func nativeBoundedWorkPreview(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    var lines = value.components(separatedBy: .newlines)
    while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        lines.removeFirst()
    }
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        lines.removeLast()
    }
    let bounded = lines.suffix(64).map { line -> String in
        var sanitized = String.UnicodeScalarView()
        for scalar in line.unicodeScalars.prefix(240) {
            if scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar) {
                sanitized.append(scalar)
            } else {
                sanitized.append(" ")
            }
        }
        return String(sanitized)
    }
    let preview = bounded.joined(separator: "\n")
    return preview.isEmpty ? nil : preview
}

func nativeWorkPreviewSnippet(_ value: String?) -> String? {
    guard let preview = nativeBoundedWorkPreview(value) else {
        return nil
    }
    return nativeWorkPreviewSnippetFromBounded(preview)
}

func nativeWorkPreviewSnippetFromBounded(_ preview: String) -> String? {
    let lines =
        preview
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        return nil
    }
    return lines.suffix(2).joined(separator: "\n")
}
