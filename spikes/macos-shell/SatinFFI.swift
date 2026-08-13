import Darwin
import Foundation

@_silgen_name("satin_core_create")
func satinCoreCreate() -> UnsafeMutableRawPointer?

@_silgen_name("satin_core_create_with_theme")
func satinCoreCreateWithTheme(_ theme: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

@_silgen_name("satin_core_destroy")
func satinCoreDestroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_core_new_tab")
func satinCoreNewTab(_ handle: UnsafeMutableRawPointer?) -> Int

@_silgen_name("satin_core_split_active")
func satinCoreSplitActive(_ handle: UnsafeMutableRawPointer?, _ axis: UInt32) -> Int

@_silgen_name("satin_core_resize_split")
func satinCoreResizeSplit(
    _ handle: UnsafeMutableRawPointer?,
    _ firstPaneId: Int,
    _ secondPaneId: Int,
    _ ratio: Double
) -> UInt8

@_silgen_name("satin_core_close_pane")
func satinCoreClosePane(_ handle: UnsafeMutableRawPointer?, _ paneId: Int) -> UInt8

@_silgen_name("satin_core_select_tab")
func satinCoreSelectTab(_ handle: UnsafeMutableRawPointer?, _ index: Int) -> UInt8

@_silgen_name("satin_core_move_tab")
func satinCoreMoveTab(_ handle: UnsafeMutableRawPointer?, _ tabId: Int, _ index: Int) -> UInt8

@_silgen_name("satin_core_select_pane")
func satinCoreSelectPane(_ handle: UnsafeMutableRawPointer?, _ paneId: Int) -> UInt8

@_silgen_name("satin_core_pane_in_direction")
func satinCorePaneInDirection(_ handle: UnsafeMutableRawPointer?, _ direction: UInt32) -> Int

@_silgen_name("satin_core_rename_tab")
func satinCoreRenameTab(
    _ handle: UnsafeMutableRawPointer?,
    _ index: Int,
    _ title: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_core_set_tab_theme")
func satinCoreSetTabTheme(
    _ handle: UnsafeMutableRawPointer?,
    _ index: Int,
    _ theme: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_core_set_default_theme")
func satinCoreSetDefaultTheme(
    _ handle: UnsafeMutableRawPointer?,
    _ theme: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_core_snapshot_json")
func satinCoreSnapshotJson(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_core_apply_workspace_json")
func satinCoreApplyWorkspaceJson(
    _ handle: UnsafeMutableRawPointer?,
    _ workspace: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_runtime_create")
func satinRuntimeCreate(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_create_in_cwd")
func satinRuntimeCreateInCwd(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ cwd: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_create_config")
func satinRuntimeCreateConfig(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ config: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_create_external")
func satinRuntimeCreateExternal(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_destroy")
func satinRuntimeDestroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_runtime_resize")
func satinRuntimeResize(
    _ handle: UnsafeMutableRawPointer?,
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UInt8

@_silgen_name("satin_runtime_write")
func satinRuntimeWrite(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ len: Int
) -> UInt8

@_silgen_name("satin_runtime_key")
func satinRuntimeKey(
    _ handle: UnsafeMutableRawPointer?,
    _ keyCode: UInt16,
    _ modifiers: UInt32,
    _ text: UnsafePointer<UInt8>?,
    _ textLength: Int,
    _ unshifted: UnsafePointer<UInt8>?,
    _ unshiftedLength: Int,
    _ repeated: UInt8,
    _ released: UInt8
) -> UInt8

@_silgen_name("satin_runtime_text")
func satinRuntimeText(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_paste")
func satinRuntimePaste(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_take_tmux_event_json")
func satinRuntimeTakeTmuxEventJson(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_tmux_command")
func satinRuntimeTmuxCommand(
    _ handle: UnsafeMutableRawPointer?,
    _ command: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_runtime_tmux_feed_pane")
func satinRuntimeTmuxFeedPane(
    _ pane: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_tmux_shell_prompt_state")
func satinRuntimeTmuxShellPromptState(
    _ pane: UnsafeMutableRawPointer?
) -> UInt8

@_silgen_name("satin_runtime_tmux_semantic_prompt_seen")
func satinRuntimeTmuxSemanticPromptSeen(
    _ pane: UnsafeMutableRawPointer?
) -> UInt8

@_silgen_name("satin_runtime_tmux_prompt_generation")
func satinRuntimeTmuxPromptGeneration(
    _ pane: UnsafeMutableRawPointer?
) -> UInt64

@_silgen_name("satin_runtime_tmux_reset_prompt_tracking")
func satinRuntimeTmuxResetPromptTracking(
    _ pane: UnsafeMutableRawPointer?
) -> UInt8

@_silgen_name("satin_runtime_tmux_key")
func satinRuntimeTmuxKey(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ keyCode: UInt16,
    _ modifiers: UInt32,
    _ text: UnsafePointer<UInt8>?,
    _ textLength: Int,
    _ unshifted: UnsafePointer<UInt8>?,
    _ unshiftedLength: Int,
    _ repeated: UInt8,
    _ released: UInt8
) -> UInt8

@_silgen_name("satin_runtime_tmux_write")
func satinRuntimeTmuxWrite(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_tmux_paste")
func satinRuntimeTmuxPaste(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_tmux_mouse")
func satinRuntimeTmuxMouse(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ action: UInt32,
    _ button: Int32,
    _ modifiers: UInt32,
    _ x: Float,
    _ y: Float,
    _ cellWidth: UInt32,
    _ cellHeight: UInt32
) -> UInt8

@_silgen_name("satin_runtime_tmux_focus")
func satinRuntimeTmuxFocus(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ focused: UInt8
) -> UInt8

@_silgen_name("satin_runtime_mouse")
func satinRuntimeMouse(
    _ handle: UnsafeMutableRawPointer?,
    _ action: UInt32,
    _ button: Int32,
    _ modifiers: UInt32,
    _ x: Float,
    _ y: Float,
    _ cellWidth: UInt32,
    _ cellHeight: UInt32
) -> UInt8

@_silgen_name("satin_runtime_mouse_tracking")
func satinRuntimeMouseTracking(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_focus")
func satinRuntimeFocus(
    _ handle: UnsafeMutableRawPointer?,
    _ focused: UInt8
) -> UInt8

@_silgen_name("satin_runtime_selection_event")
func satinRuntimeSelectionEvent(
    _ handle: UnsafeMutableRawPointer?,
    _ action: UInt32,
    _ row: UInt32,
    _ col: UInt16,
    _ x: Float,
    _ y: Float,
    _ cellWidth: UInt32,
    _ rectangular: UInt8
) -> Int

@_silgen_name("satin_runtime_select_all")
func satinRuntimeSelectAll(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_clear_selection")
func satinRuntimeClearSelection(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_selected_text")
func satinRuntimeSelectedText(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_hyperlink")
func satinRuntimeHyperlink(
    _ handle: UnsafeMutableRawPointer?,
    _ row: UInt32,
    _ col: UInt16
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_title")
func satinRuntimeTitle(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_take_bell_count")
func satinRuntimeTakeBellCount(_ handle: UnsafeMutableRawPointer?) -> UInt64

@_silgen_name("satin_runtime_find")
func satinRuntimeFind(
    _ handle: UnsafeMutableRawPointer?,
    _ query: UnsafePointer<CChar>?,
    _ backwards: UInt8
) -> UInt8

@_silgen_name("satin_runtime_set_option_as_alt")
func satinRuntimeSetOptionAsAlt(
    _ handle: UnsafeMutableRawPointer?,
    _ enabled: UInt8
) -> UInt8

@_silgen_name("satin_runtime_drain")
func satinRuntimeDrain(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_exited")
func satinRuntimeExited(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_wakeup_fd")
func satinRuntimeWakeupFd(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_runtime_scroll")
func satinRuntimeScroll(_ handle: UnsafeMutableRawPointer?, _ requestedRows: Int) -> Int

@_silgen_name("satin_runtime_renderer_scroll_position")
func satinRuntimeRendererScrollPosition(_ handle: UnsafeMutableRawPointer?) -> Float

@_silgen_name("satin_runtime_cursor_position")
func satinRuntimeCursorPosition(_ handle: UnsafeMutableRawPointer?) -> UInt32

@_silgen_name("satin_runtime_cwd")
func satinRuntimeCwd(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_screen_text")
func satinRuntimeScreenText(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_kitty_placement_count")
func satinRuntimeKittyPlacementCount(_ handle: UnsafeMutableRawPointer?) -> Int

@_silgen_name("satin_nvim_create")
func satinNvimCreate(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_nvim_create_in_cwd")
func satinNvimCreateInCwd(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ cwd: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_nvim_create_with_config")
func satinNvimCreateWithConfig(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ configuration: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_nvim_destroy")
func satinNvimDestroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_nvim_resize")
func satinNvimResize(
    _ handle: UnsafeMutableRawPointer?,
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UInt8

@_silgen_name("satin_nvim_input")
func satinNvimInput(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ len: Int
) -> UInt8

@_silgen_name("satin_nvim_mouse")
func satinNvimMouse(
    _ handle: UnsafeMutableRawPointer?,
    _ button: UnsafePointer<CChar>?,
    _ action: UnsafePointer<CChar>?,
    _ modifier: UnsafePointer<CChar>?,
    _ grid: Int64,
    _ row: Int64,
    _ col: Int64
) -> UInt8

@_silgen_name("satin_nvim_take_message_selection_text")
func satinNvimTakeMessageSelectionText(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_nvim_command")
func satinNvimCommand(
    _ handle: UnsafeMutableRawPointer?,
    _ command: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_nvim_drain")
func satinNvimDrain(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_nvim_exited")
func satinNvimExited(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_nvim_exit_code")
func satinNvimExitCode(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_nvim_wakeup_fd")
func satinNvimWakeupFd(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_nvim_kitty_placement_count")
func satinNvimKittyPlacementCount(_ handle: UnsafeMutableRawPointer?) -> Int

@_silgen_name("satin_nvim_renderer_model_json")
func satinNvimRendererModelJson(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<
    CChar
>?

@_silgen_name("satin_nvim_ui_state_json")
func satinNvimUiStateJson(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_string_free")
func satinStringFree(_ value: UnsafeMutablePointer<CChar>?)

@_silgen_name("satin_skia_metal_create")
func satinSkiaMetalCreate(
    _ device: UnsafeMutableRawPointer?,
    _ commandQueue: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_skia_metal_destroy")
func satinSkiaMetalDestroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_skia_metal_render_nvim")
func satinSkiaMetalRenderNvim(
    _ renderer: UnsafeMutableRawPointer?,
    _ nvim: UnsafeMutableRawPointer?,
    _ texture: UnsafeMutableRawPointer?,
    _ width: Int32,
    _ height: Int32,
    _ originX: Float,
    _ originY: Float,
    _ contentWidth: Float,
    _ contentHeight: Float,
    _ cellWidth: Float,
    _ cellHeight: Float,
    _ clear: UInt8
) -> UInt8

@_silgen_name("satin_skia_metal_render_terminal")
func satinSkiaMetalRenderTerminal(
    _ renderer: UnsafeMutableRawPointer?,
    _ runtime: UnsafeMutableRawPointer?,
    _ texture: UnsafeMutableRawPointer?,
    _ width: Int32,
    _ height: Int32,
    _ originX: Float,
    _ originY: Float,
    _ contentWidth: Float,
    _ contentHeight: Float,
    _ cellWidth: Float,
    _ cellHeight: Float,
    _ clear: UInt8
) -> UInt8

@_silgen_name("satin_skia_metal_needs_animation_frame")
func satinSkiaMetalNeedsAnimationFrame(_ renderer: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_skia_metal_forget_runtime")
func satinSkiaMetalForgetRuntime(
    _ renderer: UnsafeMutableRawPointer?,
    _ runtime: UnsafeMutableRawPointer?
)

@_silgen_name("satin_skia_metal_set_font_family")
func satinSkiaMetalSetFontFamily(
    _ renderer: UnsafeMutableRawPointer?,
    _ family: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_skia_metal_next_frame_delay_ms")
func satinSkiaMetalNextFrameDelayMs(_ renderer: UnsafeMutableRawPointer?) -> UInt64
