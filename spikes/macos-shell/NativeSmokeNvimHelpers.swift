import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func nvimFloatCommand() -> String {
            "lua vim.api.nvim_set_hl(0,'NormalFloat',{bg='#506070',blend=35}); "
                + "vim.api.nvim_set_hl(0,'SatinTransparentFloat',{bg='#506070',blend=100}); "
                + "local b=vim.api.nvim_create_buf(false,true); "
                + "vim.api.nvim_buf_set_lines(b,0,-1,false,{' FLOATBOX'}); "
                + "local config={relative='editor',row=3,col=20,width=16,height=3,style='minimal',zindex=50}; "
                + "local w=vim.api.nvim_open_win(b,false,config); "
                + "vim.wo[w].winblend=35; vim.wo[w].winhl='Normal:NormalFloat'; "
                + "local overlay=vim.api.nvim_create_buf(false,true); "
                + "vim.api.nvim_buf_set_lines(overlay,0,-1,false,{'','',''}); "
                + "local overlay_config={relative='editor',row=3,col=21,width=15,height=3,"
                + "style='minimal',zindex=50,focusable=false}; "
                + "local ow=vim.api.nvim_open_win(overlay,false,overlay_config); "
                + "vim.wo[ow].winblend=100; vim.wo[ow].winhl='Normal:SatinTransparentFloat'"
        }

        func nvimSmokeStatuslineCommand() -> String {
            "lua vim.o.laststatus=2; vim.o.statusline='STATUSLINE'; "
                + "for _,w in ipairs(vim.api.nvim_list_wins()) do "
                + "pcall(vim.api.nvim_set_option_value,'statusline','STATUSLINE',{win=w}) end; "
                + "vim.cmd('redrawstatus!')"
        }

        func nvimPopupmenuSetupCommand() -> String {
            [
                "enew!",
                "setlocal norelativenumber nonumber",
                "call setline(1, ['POPUPANCHOR'])",
                "set wildmenu wildmode=full",
                "lua vim.api.nvim_create_user_command('NvtermPopupDummy', "
                    + "function(opts) vim.print(opts.args) end, "
                    + "{nargs=1, complete=function() return {'POPUPONE','POPUPTWO'} end})",
            ].joined(separator: " | ")
        }

        func nvimFileTreeOpenCommand() -> String {
            "set mouse=a | lua " + "if vim.fn.exists(':NvimTreeToggle') == 2 then "
                + "vim.cmd('NvimTreeToggle'); "
                + "if vim.fn.exists(':NvimTreeFocus') == 2 then vim.cmd('NvimTreeFocus') end "
                + "elseif vim.fn.exists(':Neotree') == 2 then "
                + "vim.cmd('Neotree filesystem reveal left') end"
        }

        func nvimFileTreeCloseCommand() -> String {
            "lua if vim.fn.exists(':NvimTreeClose') == 2 then " + "vim.cmd('NvimTreeClose') "
                + "elseif vim.fn.exists(':Neotree') == 2 then vim.cmd('Neotree close') end"
        }

        func clickNvimFileTreeSmokeTarget() {
            guard let position = terminalTextView.rendererModelTextStartPosition("Cargo.toml")
            else {
                smokeState.nvimFileTreeTarget = "none"
                return
            }
            smokeState.nvimFileTreeTarget = "\(position.row):\(position.col)"
            sendNvimMouseClick(row: Int64(position.row), col: Int64(position.col))
        }

        func sendNvimMouseClick(row: Int64, col: Int64) {
            let press = NativeMouseInput(
                button: "left",
                action: "press",
                modifier: "",
                grid: 0,
                row: row,
                col: col
            )
            let release = NativeMouseInput(
                button: "left",
                action: "release",
                modifier: "",
                grid: 0,
                row: row,
                col: col
            )
            _ = sendMouseInputToActivePane(press)
            _ = sendMouseInputToActivePane(release)
        }

        func exerciseNvimMessageSelectionSmoke() {
            guard let position = terminalTextView.rendererModelTextStartPosition("MSGBOX") else {
                smokeState.nvimMessageSelection = "overlay=no copied=no reason=missing-message"
                return
            }
            let pasteboard = NSPasteboard.general
            let previousItems: [NSPasteboardItem] =
                pasteboard.pasteboardItems?.map { source in
                    let copy = NSPasteboardItem()
                    for type in source.types {
                        if let data = source.data(forType: type) {
                            copy.setData(data, forType: type)
                        }
                    }
                    return copy
                } ?? []
            defer {
                pasteboard.clearContents()
                if !previousItems.isEmpty {
                    pasteboard.writeObjects(previousItems)
                }
            }

            let start = NativeMouseInput(
                button: "left",
                action: "press",
                modifier: "",
                grid: 0,
                row: Int64(position.row),
                col: Int64(position.col)
            )
            let endCol = Int64(position.col + "MSGBOX".count - 1)
            let drag = NativeMouseInput(
                button: "left",
                action: "drag",
                modifier: "",
                grid: 0,
                row: Int64(position.row),
                col: endCol
            )
            let release = NativeMouseInput(
                button: "left",
                action: "release",
                modifier: "",
                grid: 0,
                row: Int64(position.row),
                col: endCol
            )
            let pressHandling = sendMouseInputToActivePane(start)
            let dragHandling = sendMouseInputToActivePane(drag)
            let overlay = terminalTextView.rendererModelMessageSelectionSummary()
            let releaseHandling = sendMouseInputToActivePane(release)
            let copied = pasteboard.string(forType: .string) == "MSGBOX"
            let handled =
                pressHandling == .messageSelection && dragHandling == .messageSelection
                && releaseHandling == .messageSelection
            smokeState.nvimMessageSelection = [
                "overlay=\(handled && overlay != "none" ? "yes" : "no")",
                "copied=\(copied ? "yes" : "no")",
                "selection=\(overlay)",
            ].joined(separator: " ")
        }

        func configureNvimCursorSmokeTab(marker: String, cursorRow: Int, cursorCol: Int) {
            let rowNumber = cursorRow + 1
            let colNumber = cursorCol + 1
            let command = [
                "enew!",
                "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
                "call setline(1, ['\(marker)'] + repeat([repeat(' ', 100)], 40))",
                "normal! \(rowNumber)G\(colNumber)|",
            ].joined(separator: " | ")
            runNvimCommandOrWrite(command, fallback: Data(":enew\r".utf8))
        }

        func configureNvimCursorShapeSmoke() {
            let command = [
                "enew!",
                "set guicursor=i:ver25-blinkon0",
                "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
                "call setline(1, ['CURSORSHAPE'] + repeat([repeat(' ', 100)], 20))",
                "call cursor(6, 12)",
                "startinsert",
            ].joined(separator: " | ")
            runNvimCommandOrWrite(command, fallback: Data(":startinsert\r".utf8))
        }

        func clearMarkedTextForVisualSmoke() {
            terminalTextView.inputContext?.discardMarkedText()
            terminalTextView.unmarkText()
        }

        func configureNvimCursorNormalShapeSmoke() {
            let command = [
                "enew!",
                "set guicursor=n:block-blinkon0",
                "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
                "call setline(1, ['CURSORNORMAL'] + repeat([repeat(' ', 100)], 20))",
                "call cursor(6, 12)",
                "stopinsert",
            ].joined(separator: " | ")
            runNvimCommandOrWrite(command, fallback: Data("\u{1b}".utf8))
        }

        func configureNvimCursorReplaceShapeSmoke() {
            let command = [
                "enew!",
                "set guicursor=r:hor20-blinkon0",
                "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
                "call setline(1, ['CURSORREPLACE'] + repeat([repeat(' ', 100)], 20))",
                "call cursor(6, 12)",
                "startreplace",
            ].joined(separator: " | ")
            runNvimCommandOrWrite(command, fallback: Data(":startreplace\r".utf8))
        }

        func configureNvimCursorBlinkSmoke() {
            let command = [
                "enew!",
                "set guicursor=i:ver25-blinkwait100-blinkon100-blinkoff2000",
                "setlocal norelativenumber nonumber laststatus=0 noruler noshowmode virtualedit=all",
                "call setline(1, ['CURSORBLINK'] + repeat([repeat(' ', 100)], 20))",
                "call cursor(6, 12)",
                "startinsert",
            ].joined(separator: " | ")
            runNvimCommandOrWrite(command, fallback: Data(":startinsert\r".utf8))
        }

        func configureNvimPopupmenuSmoke() {
            runNvimCommandOrWrite(
                nvimPopupmenuSetupCommand(),
                fallback: Data(":echo 'POPUPONE'\r".utf8)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.writeToActivePane(Data(":NvtermPopupDummy P\t".utf8))
            }
        }

        func configureNvimSkiaSmoke() {
            let command = [
                "enew!",
                "set laststatus=0 noruler noshowmode",
                "setlocal norelativenumber nonumber signcolumn=no foldcolumn=0 virtualedit=all",
                "call setline(1, ['SKIASMOKE', 'renderer basic smoke'])",
                "call cursor(2, 1)",
            ].joined(separator: " | ")
            runNvimCommandOrWrite(command, fallback: Data(":enew\r".utf8))
        }

        func sendNvimImageSmokePlacement() {
            let png =
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA"
                + "DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
            let lua = [
                "local e=string.char(27)",
                "local packet=e..'[4;6H'..e..'_Ga=T,f=100,t=d,i=901,z=0,w=240,h=160,q=2;" + png
                    + "'..e..'\\\\'",
                "require('satin.image').write(packet)",
            ].joined(separator: ";")
            runNvimCommandOrWrite("lua \(lua)", fallback: Data())
        }

        func openNvimSmokeBuffer(path: String, terminalCommand: String) {
            writeSmokeLines(path: path)
            switch activePaneMode() {
            case .terminal:
                let command = [
                    "tmp=\(path)",
                    "seq 1 300 > $tmp",
                    terminalCommand,
                ].joined(separator: "; ")
                writeToActivePane(Data("\(command)\r".utf8))
            case .neovim:
                scheduleNvimCommand(
                    neovimEditTopCommand(path),
                    paneId: activePaneId,
                    fallback: Data(":edit \(path)\r".utf8)
                )
            }
        }

        func openNvimShapedTextSmokeBuffer(path: String, terminalCommand: String) {
            writeShapedTextSmokeLines(path: path)
            switch activePaneMode() {
            case .terminal:
                let command = [
                    "tmp=\(path)",
                    terminalCommand,
                ].joined(separator: "; ")
                writeToActivePane(Data("\(command)\r".utf8))
            case .neovim:
                scheduleNvimCommand(
                    neovimEditTopCommand(path),
                    paneId: activePaneId,
                    fallback: Data(":edit \(path)\r".utf8)
                )
            }
        }

        func writeSmokeLines(path: String) {
            let lines = [nvimSmokeReadyMarker] + (1...300).map(String.init)
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }

        func writeShapedTextSmokeLines(path: String) {
            let lines = [
                "shaped 日本語 \u{e0b0} e\u{301} Ω",
                "latin ABC xyz",
                "nerd \u{e0b2}\u{f013}",
                "combining a\u{0308}",
                "ambiguous ·→",
            ]
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }

        func nvimAnimationSmokeSummary(
            _ shift: OutputScrollShift?,
            hasModelFrames: Bool,
            skiaFrames: Int
        ) -> String {
            let rendererSummary =
                "model-frames=\(hasModelFrames ? "yes" : "no") "
                + "skia-frames=\(skiaFrames > 0 ? "yes" : "no") count=\(skiaFrames)"
            guard let shift else {
                return "missing-scroll-region-shift \(rendererSummary)"
            }
            var columns = ""
            if let startCol = shift.startCol, let endCol = shift.endCol {
                columns = " cols=\(startCol)..\(endCol)"
            }
            return "rows=\(shift.rows) start=\(shift.startRow) end=\(shift.endRow)\(columns) "
                + rendererSummary
        }

        func clearSmokeScrollShift() {
            lastNvimModelScrollShift = nil
        }

        func consumeSmokeScrollShift() -> OutputScrollShift? {
            defer {
                lastNvimModelScrollShift = nil
            }
            return lastNvimModelScrollShift
        }

        func peekSmokeScrollShift() -> OutputScrollShift? {
            lastNvimModelScrollShift
        }

        func activePaneRendererScrollPosition() -> Double {
            guard let paneId = activePaneId,
                let pane = paneStore.runtimes[paneId] as? RustTerminalPane
            else {
                return 0
            }
            return pane.rendererScrollPosition()
        }

        func runNvimCommandOrWrite(_ command: String, fallback: Data) {
            if !runNvimCommand(command) {
                writeToActivePane(fallback)
            }
        }

        @discardableResult
        func runNvimCommand(_ command: String) -> Bool {
            guard let paneId = activePaneId,
                let pane = paneStore.runtimes[paneId] as? RustNeovimPane
            else {
                return false
            }
            let ok = pane.runCommand(command)
            if ok {
                drainTerminalPanes()
            }
            return ok
        }

    }
#endif
