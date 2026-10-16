import AppKit

/// A Markdown page set as a document: proportional type, headings by size,
/// code and tables in their own blocks, in the colors of the current look.
enum NativePageMarkdown {
    /// The widest a line of body text runs before the margins grow.
    static let measure: CGFloat = 720

    static func render(_ markdown: String, images: URL? = nil) -> NSAttributedString {
        guard
            let parsed = try? AttributedString(
                markdown: markdown,
                options: .init(
                    interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
        else {
            return NSAttributedString(
                string: markdown,
                attributes: [.font: body(), .foregroundColor: NativePageStyle.text])
        }
        let out = NSMutableAttributedString()
        var block: PresentationIntent?
        var blockStart = 0
        var listItems = Set<Int>()
        var tables: [Int: NSTextTable] = [:]
        let characters = parsed.characters
        var boxed = false
        func finishBlock() {
            guard let intent = block else {
                return
            }
            out.append(NSAttributedString(string: "\n"))
            let range = NSRange(location: blockStart, length: out.length - blockStart)
            style(out, range: range, intent: intent, tables: &tables)
            boxed = isTableCell(intent) || isCode(intent)
        }
        for run in parsed.runs {
            let intent = run.presentationIntent
            if intent != block {
                finishBlock()
                // A table or a code block is boxed; what follows a box stands
                // clear of it on a short empty line of its own.
                if boxed, !(isTableCell(intent) && isTableCell(block)) {
                    out.append(spacer())
                }
                block = intent
                blockStart = out.length
                if let intent,
                    let item = intent.components.first(where: {
                        if case .listItem = $0.kind { return true }
                        return false
                    }), listItems.insert(item.identity).inserted
                {
                    out.append(marker(for: intent, item: item))
                }
            }
            var text = String(characters[run.range])
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.softBreak) {
                let before = characters[..<run.range.lowerBound].last
                let after =
                    run.range.upperBound < characters.endIndex
                    ? characters[run.range.upperBound] : nil
                text = isWide(before) && isWide(after) ? "" : " "
            } else if inline.contains(.lineBreak) {
                text = "\u{2028}"
            }
            if isCode(intent) && text.hasSuffix("\n") {
                text.removeLast()
            }
            if let url = run.imageURL, let attachment = image(url, in: images) {
                out.append(NSAttributedString(attachment: attachment))
                continue
            }
            out.append(
                NSAttributedString(
                    string: text, attributes: attributes(inline, run: run, intent: intent)))
        }
        finishBlock()
        if out.length > 0 {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    private static func spacer() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 12
        paragraph.maximumLineHeight = 12
        return NSAttributedString(
            string: "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: paragraph])
    }

    // MARK: Inline

    private static func body() -> NSFont {
        NativePageStyle.sans(14.5)
    }

    private static func attributes(
        _ inline: InlinePresentationIntent, run: AttributedString.Runs.Run,
        intent: PresentationIntent?
    ) -> [NSAttributedString.Key: Any] {
        var font = isCode(intent) ? NativePageStyle.mono(12.5, .regular) : body()
        var color = NativePageStyle.text
        if let level = header(intent) {
            font = headingFont(level)
        } else if isQuote(intent) {
            color = NativePageStyle.muted
        }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if inline.contains(.code) {
            font = NativePageStyle.mono(font.pointSize - 1.5, .regular)
            attributes[.backgroundColor] = NativePageStyle.text.withAlphaComponent(0.07)
        }
        if inline.contains(.stronglyEmphasized) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if inline.contains(.emphasized) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
            attributes[.link] = link
            color = NativePageStyle.teal
        }
        attributes[.font] = font
        attributes[.foregroundColor] = color
        return attributes
    }

    private static func headingFont(_ level: Int) -> NSFont {
        let size: CGFloat = [26, 20, 16.5, 15][min(level, 4) - 1]
        if NativePageStyle.paper, level <= 2 {
            return NativePageStyle.serif(size + 2)
        }
        return NativePageStyle.sans(size, level <= 2 ? .bold : .semibold)
    }

    /// Lines of CJK text break without a space between them.
    private static func isWide(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first?.value else {
            return false
        }
        return (0x2E80...0x9FFF).contains(scalar) || (0xF900...0xFAFF).contains(scalar)
            || (0xFF00...0xFFEF).contains(scalar)
    }

    /// A PNG beside the page; remote and outside images are left out.
    private static func image(_ url: URL, in folder: URL?) -> NSTextAttachment? {
        guard let folder, url.scheme == nil || url.isFileURL else {
            return nil
        }
        let file = URL(fileURLWithPath: url.relativePath, relativeTo: folder).standardizedFileURL
        guard file.path.hasPrefix(folder.standardizedFileURL.path + "/"),
            file.pathExtension.lowercased() == "png",
            let picture = NSImage(contentsOf: file)
        else {
            return nil
        }
        let scale = min(1, measure / max(1, picture.size.width))
        let attachment = NSTextAttachment()
        attachment.image = picture
        attachment.bounds = NSRect(
            x: 0, y: 0, width: picture.size.width * scale, height: picture.size.height * scale)
        return attachment
    }

    // MARK: Blocks

    private static func header(_ intent: PresentationIntent?) -> Int? {
        for component in intent?.components ?? [] {
            if case .header(let level) = component.kind {
                return level
            }
        }
        return nil
    }

    private static func isCode(_ intent: PresentationIntent?) -> Bool {
        intent?.components.contains {
            if case .codeBlock = $0.kind { return true }
            return false
        } ?? false
    }

    private static func isTableCell(_ intent: PresentationIntent?) -> Bool {
        intent?.components.contains {
            if case .tableCell = $0.kind { return true }
            return false
        } ?? false
    }

    private static func isQuote(_ intent: PresentationIntent?) -> Bool {
        intent?.components.contains { $0.kind == .blockQuote } ?? false
    }

    private static func listDepth(_ intent: PresentationIntent) -> Int {
        intent.components.filter {
            if case .listItem = $0.kind { return true }
            return false
        }.count
    }

    private static func marker(
        for intent: PresentationIntent, item: PresentationIntent.IntentType
    ) -> NSAttributedString {
        guard case .listItem(let ordinal) = item.kind else {
            return NSAttributedString()
        }
        let ordered =
            intent.components.first {
                switch $0.kind {
                case .orderedList, .unorderedList: return true
                default: return false
                }
            }?.kind == .orderedList
        return NSAttributedString(
            string: ordered ? "\(ordinal).\t" : "•\t",
            attributes: [
                .font: body(),
                .foregroundColor: ordered ? NativePageStyle.muted : NativePageStyle.teal,
            ])
    }

    private static func style(
        _ out: NSMutableAttributedString, range: NSRange, intent: PresentationIntent,
        tables: inout [Int: NSTextTable]
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.3
        paragraph.paragraphSpacing = 10
        let depth = listDepth(intent)
        if depth > 0 {
            let indent = CGFloat(depth) * 22
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = indent - 16
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            paragraph.paragraphSpacing = 4
        }
        if let level = header(intent) {
            paragraph.paragraphSpacingBefore = level <= 2 ? 18 : 12
            paragraph.paragraphSpacing = 6
            paragraph.lineHeightMultiple = 1.1
        }
        for component in intent.components {
            switch component.kind {
            case .codeBlock:
                let block = NSTextBlock()
                block.backgroundColor = NativePageStyle.text.withAlphaComponent(0.06)
                block.setWidth(12, type: .absoluteValueType, for: .padding)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(NativePageStyle.line)
                block.setValue(100, type: .percentageValueType, for: .width)
                paragraph.textBlocks = [block]
                paragraph.lineHeightMultiple = 1.15
                paragraph.paragraphSpacing = 0
                paragraph.paragraphSpacingBefore = 0
            case .blockQuote:
                let bar = NSTextBlock()
                bar.setValue(100, type: .percentageValueType, for: .width)
                bar.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                bar.setBorderColor(NativePageStyle.teal.withAlphaComponent(0.7), for: .minX)
                bar.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
                bar.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
                bar.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
                paragraph.textBlocks = [bar]
            case .thematicBreak:
                out.replaceCharacters(
                    in: NSRange(location: range.location, length: 0), with: "· · ·")
                paragraph.alignment = .center
                out.addAttribute(
                    .foregroundColor, value: NativePageStyle.muted,
                    range: NSRange(location: range.location, length: 5))
            case .tableCell(let column):
                guard
                    let table = intent.components.first(where: {
                        if case .table = $0.kind { return true }
                        return false
                    }), case .table(let columns) = table.kind
                else {
                    continue
                }
                let textTable = tables[table.identity] ?? makeTable(columns.count)
                tables[table.identity] = textTable
                let row =
                    intent.components.compactMap { component -> Int? in
                        switch component.kind {
                        case .tableHeaderRow: return 0
                        case .tableRow(let index): return index
                        default: return nil
                        }
                    }.first ?? 0
                let cell = NSTextTableBlock(
                    table: textTable, startingRow: row, rowSpan: 1, startingColumn: column,
                    columnSpan: 1)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(NativePageStyle.line)
                cell.setWidth(7, type: .absoluteValueType, for: .padding)
                if row == 0 {
                    cell.backgroundColor = NativePageStyle.teal.withAlphaComponent(0.12)
                    out.applyFontTraits(.boldFontMask, range: range)
                }
                paragraph.textBlocks = [cell]
                paragraph.paragraphSpacing = 0
                paragraph.lineHeightMultiple = 1.15
                switch columns[min(column, columns.count - 1)].alignment {
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                default: break
                }
            default:
                break
            }
        }
        out.addAttribute(.paragraphStyle, value: paragraph, range: range)
    }

    private static func makeTable(_ columns: Int) -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = max(1, columns)
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        return table
    }
}

/// The reader's page: the rendered document in a scroll view laid over the
/// reader's pane, which stays behind it for the control API.
final class NativePageDocumentView: NSScrollView {
    private let textView: NSTextView
    private var markdown = ""
    private var images: URL?
    private(set) var shown: String?

    override init(frame frameRect: NSRect) {
        textView = NSTextView(usingTextLayoutManager: false)
        super.init(frame: frameRect)
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 32, height: 26)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: frameRect.width, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(origin: .zero, size: frameRect.size)
        documentView = textView
        setAccessibilityRole(.textArea)
        refreshLook()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Shows a page's Markdown; key names what is shown, so the same version
    /// is not set again.
    func show(markdown: String, images: URL?, key: String) {
        guard key != shown else {
            return
        }
        shown = key
        self.markdown = markdown
        self.images = images
        render()
        textView.scroll(.zero)
    }

    func refreshLook() {
        // The page continues the sheet the reader's frame draws around it.
        let sheet = NativePageStyle.paper ? NativePageStyle.raised : NativePageStyle.surface
        backgroundColor = sheet
        textView.backgroundColor = sheet
        textView.selectedTextAttributes = [
            .backgroundColor: NativePageStyle.teal.withAlphaComponent(0.28)
        ]
        textView.linkTextAttributes = [
            .foregroundColor: NativePageStyle.teal,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        render()
    }

    /// Space and the page keys scroll by a screen; the arrows by a few lines.
    func scroll(lines: CGFloat? = nil, down: Bool) {
        let step = lines.map { $0 * 22 } ?? max(40, contentView.bounds.height - 60)
        var origin = contentView.bounds.origin
        let limit = max(0, textView.frame.height - contentView.bounds.height)
        origin.y = min(limit, max(0, origin.y + (down ? step : -step)))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    override func layout() {
        super.layout()
        // The text runs the width of the view and grows down as it needs.
        let width = contentSize.width
        if textView.frame.width != width {
            textView.setFrameSize(
                NSSize(width: width, height: max(textView.frame.height, contentSize.height)))
        }
        let side = max(32, (bounds.width - NativePageMarkdown.measure) / 2)
        if textView.textContainerInset.width != side {
            textView.textContainerInset = NSSize(width: side, height: 26)
        }
    }

    private func render() {
        guard shown != nil else {
            return
        }
        textView.textStorage?.setAttributedString(
            NativePageMarkdown.render(markdown, images: images))
    }
}

func runNativePageDocumentSelfTests() -> Bool {
    let text = NativePageMarkdown.render(
        "# 見出し\n\n同じ版の\nガイド and\nmore **bold**\n\n- one\n- two\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
    )
    let string = text.string
    guard string.contains("同じ版のガイド and more bold"), string.contains("•\tone"),
        string.contains("•\ttwo")
    else {
        return false
    }
    var tables = 0
    text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) {
        value, _, _ in
        if (value as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock {
            tables += 1
        }
    }
    let heading = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    return tables >= 4 && (heading?.pointSize ?? 0) > 20
}
