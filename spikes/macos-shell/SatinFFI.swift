import Darwin
import Foundation

@_silgen_name("satin_core_create")
func satin_core_create() -> UnsafeMutableRawPointer?

@_silgen_name("satin_core_create_with_theme")
func satin_core_create_with_theme(_ theme: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

@_silgen_name("satin_core_destroy")
func satin_core_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_core_new_tab")
func satin_core_new_tab(_ handle: UnsafeMutableRawPointer?) -> Int

@_silgen_name("satin_core_split_active")
func satin_core_split_active(_ handle: UnsafeMutableRawPointer?, _ axis: UInt32) -> Int

@_silgen_name("satin_core_resize_split")
func satin_core_resize_split(
    _ handle: UnsafeMutableRawPointer?,
    _ firstPaneId: Int,
    _ secondPaneId: Int,
    _ ratio: Double
) -> UInt8

@_silgen_name("satin_core_close_pane")
func satin_core_close_pane(_ handle: UnsafeMutableRawPointer?, _ paneId: Int) -> UInt8

@_silgen_name("satin_core_select_tab")
func satin_core_select_tab(_ handle: UnsafeMutableRawPointer?, _ index: Int) -> UInt8

@_silgen_name("satin_core_move_tab")
func satin_core_move_tab(_ handle: UnsafeMutableRawPointer?, _ tabId: Int, _ index: Int) -> UInt8

@_silgen_name("satin_core_select_pane")
func satin_core_select_pane(_ handle: UnsafeMutableRawPointer?, _ paneId: Int) -> UInt8

@_silgen_name("satin_core_rename_tab")
func satin_core_rename_tab(
    _ handle: UnsafeMutableRawPointer?,
    _ index: Int,
    _ title: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_core_set_tab_theme")
func satin_core_set_tab_theme(
    _ handle: UnsafeMutableRawPointer?,
    _ index: Int,
    _ theme: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_core_set_default_theme")
func satin_core_set_default_theme(
    _ handle: UnsafeMutableRawPointer?,
    _ theme: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_core_snapshot_json")
func satin_core_snapshot_json(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_core_apply_workspace_json")
func satin_core_apply_workspace_json(
    _ handle: UnsafeMutableRawPointer?,
    _ workspace: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_runtime_create")
func satin_runtime_create(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_create_in_cwd")
func satin_runtime_create_in_cwd(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ cwd: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_create_config")
func satin_runtime_create_config(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ config: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_create_external")
func satin_runtime_create_external(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_runtime_destroy")
func satin_runtime_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_runtime_resize")
func satin_runtime_resize(
    _ handle: UnsafeMutableRawPointer?,
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UInt8

@_silgen_name("satin_runtime_write")
func satin_runtime_write(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ len: Int
) -> UInt8

@_silgen_name("satin_runtime_key")
func satin_runtime_key(
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
func satin_runtime_text(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_paste")
func satin_runtime_paste(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_take_tmux_event_json")
func satin_runtime_take_tmux_event_json(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_tmux_command")
func satin_runtime_tmux_command(
    _ handle: UnsafeMutableRawPointer?,
    _ command: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_runtime_tmux_feed_pane")
func satin_runtime_tmux_feed_pane(
    _ pane: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_tmux_shell_prompt_state")
func satin_runtime_tmux_shell_prompt_state(
    _ pane: UnsafeMutableRawPointer?
) -> UInt8

@_silgen_name("satin_runtime_tmux_semantic_prompt_seen")
func satin_runtime_tmux_semantic_prompt_seen(
    _ pane: UnsafeMutableRawPointer?
) -> UInt8

@_silgen_name("satin_runtime_tmux_prompt_generation")
func satin_runtime_tmux_prompt_generation(
    _ pane: UnsafeMutableRawPointer?
) -> UInt64

@_silgen_name("satin_runtime_tmux_reset_prompt_tracking")
func satin_runtime_tmux_reset_prompt_tracking(
    _ pane: UnsafeMutableRawPointer?
) -> UInt8

@_silgen_name("satin_runtime_tmux_key")
func satin_runtime_tmux_key(
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
func satin_runtime_tmux_write(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_tmux_paste")
func satin_runtime_tmux_paste(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> UInt8

@_silgen_name("satin_runtime_tmux_mouse")
func satin_runtime_tmux_mouse(
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
func satin_runtime_tmux_focus(
    _ gateway: UnsafeMutableRawPointer?,
    _ pane: UnsafeMutableRawPointer?,
    _ paneId: UInt32,
    _ focused: UInt8
) -> UInt8

@_silgen_name("satin_runtime_mouse")
func satin_runtime_mouse(
    _ handle: UnsafeMutableRawPointer?,
    _ action: UInt32,
    _ button: Int32,
    _ modifiers: UInt32,
    _ x: Float,
    _ y: Float,
    _ cellWidth: UInt32,
    _ cellHeight: UInt32
) -> UInt8

@_silgen_name("satin_runtime_focus")
func satin_runtime_focus(
    _ handle: UnsafeMutableRawPointer?,
    _ focused: UInt8
) -> UInt8

@_silgen_name("satin_runtime_select")
func satin_runtime_select(
    _ handle: UnsafeMutableRawPointer?,
    _ startRow: UInt32,
    _ startCol: UInt16,
    _ endRow: UInt32,
    _ endCol: UInt16,
    _ rectangular: UInt8
) -> UInt8

@_silgen_name("satin_runtime_select_all")
func satin_runtime_select_all(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_clear_selection")
func satin_runtime_clear_selection(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_selected_text")
func satin_runtime_selected_text(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_hyperlink")
func satin_runtime_hyperlink(
    _ handle: UnsafeMutableRawPointer?,
    _ row: UInt32,
    _ col: UInt16
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_title")
func satin_runtime_title(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_take_bell_count")
func satin_runtime_take_bell_count(_ handle: UnsafeMutableRawPointer?) -> UInt64

@_silgen_name("satin_runtime_find")
func satin_runtime_find(
    _ handle: UnsafeMutableRawPointer?,
    _ query: UnsafePointer<CChar>?,
    _ backwards: UInt8
) -> UInt8

@_silgen_name("satin_runtime_set_option_as_alt")
func satin_runtime_set_option_as_alt(
    _ handle: UnsafeMutableRawPointer?,
    _ enabled: UInt8
) -> UInt8

@_silgen_name("satin_runtime_drain")
func satin_runtime_drain(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_exited")
func satin_runtime_exited(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_runtime_wakeup_fd")
func satin_runtime_wakeup_fd(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_runtime_scroll")
func satin_runtime_scroll(_ handle: UnsafeMutableRawPointer?, _ requestedRows: Int) -> Int

@_silgen_name("satin_runtime_renderer_scroll_position")
func satin_runtime_renderer_scroll_position(_ handle: UnsafeMutableRawPointer?) -> Float

@_silgen_name("satin_runtime_cursor_position")
func satin_runtime_cursor_position(_ handle: UnsafeMutableRawPointer?) -> UInt32

@_silgen_name("satin_runtime_cwd")
func satin_runtime_cwd(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_screen_text")
func satin_runtime_screen_text(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_runtime_kitty_placement_count")
func satin_runtime_kitty_placement_count(_ handle: UnsafeMutableRawPointer?) -> Int

@_silgen_name("satin_nvim_create")
func satin_nvim_create(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_nvim_create_in_cwd")
func satin_nvim_create_in_cwd(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ cwd: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_nvim_create_with_config")
func satin_nvim_create_with_config(
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16,
    _ configuration: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_nvim_destroy")
func satin_nvim_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_nvim_resize")
func satin_nvim_resize(
    _ handle: UnsafeMutableRawPointer?,
    _ rows: UInt16,
    _ cols: UInt16,
    _ pixelWidth: UInt16,
    _ pixelHeight: UInt16
) -> UInt8

@_silgen_name("satin_nvim_input")
func satin_nvim_input(
    _ handle: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ len: Int
) -> UInt8

@_silgen_name("satin_nvim_mouse")
func satin_nvim_mouse(
    _ handle: UnsafeMutableRawPointer?,
    _ button: UnsafePointer<CChar>?,
    _ action: UnsafePointer<CChar>?,
    _ modifier: UnsafePointer<CChar>?,
    _ grid: Int64,
    _ row: Int64,
    _ col: Int64
) -> UInt8

@_silgen_name("satin_nvim_take_message_selection_text")
func satin_nvim_take_message_selection_text(
    _ handle: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_nvim_command")
func satin_nvim_command(
    _ handle: UnsafeMutableRawPointer?,
    _ command: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_nvim_drain")
func satin_nvim_drain(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_nvim_exited")
func satin_nvim_exited(_ handle: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_nvim_exit_code")
func satin_nvim_exit_code(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_nvim_wakeup_fd")
func satin_nvim_wakeup_fd(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("satin_nvim_kitty_placement_count")
func satin_nvim_kitty_placement_count(_ handle: UnsafeMutableRawPointer?) -> Int

@_silgen_name("satin_nvim_renderer_model_json")
func satin_nvim_renderer_model_json(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<
    CChar
>?

@_silgen_name("satin_nvim_ui_state_json")
func satin_nvim_ui_state_json(_ handle: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("satin_string_free")
func satin_string_free(_ value: UnsafeMutablePointer<CChar>?)

@_silgen_name("satin_skia_metal_create")
func satin_skia_metal_create(
    _ device: UnsafeMutableRawPointer?,
    _ commandQueue: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?

@_silgen_name("satin_skia_metal_destroy")
func satin_skia_metal_destroy(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("satin_skia_metal_render_nvim")
func satin_skia_metal_render_nvim(
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
func satin_skia_metal_render_terminal(
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
func satin_skia_metal_needs_animation_frame(_ renderer: UnsafeMutableRawPointer?) -> UInt8

@_silgen_name("satin_skia_metal_forget_runtime")
func satin_skia_metal_forget_runtime(
    _ renderer: UnsafeMutableRawPointer?,
    _ runtime: UnsafeMutableRawPointer?
)

@_silgen_name("satin_skia_metal_set_font_family")
func satin_skia_metal_set_font_family(
    _ renderer: UnsafeMutableRawPointer?,
    _ family: UnsafePointer<CChar>?
) -> UInt8

@_silgen_name("satin_skia_metal_next_frame_delay_ms")
func satin_skia_metal_next_frame_delay_ms(_ renderer: UnsafeMutableRawPointer?) -> UInt64
