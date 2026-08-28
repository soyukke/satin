use std::{ffi::c_char, ptr};

use crate::core::{
    PaneDirection, PaneDropPosition, SplitAxis, TerminalCore, TerminalWorkspaceInput,
};

use super::{c_string, json_ptr};

const SATIN_SPLIT_VERTICAL: u32 = 0;
const SATIN_SPLIT_HORIZONTAL: u32 = 1;
const SATIN_PANE_LEFT: u32 = 0;
const SATIN_PANE_RIGHT: u32 = 1;
const SATIN_PANE_UP: u32 = 2;
const SATIN_PANE_DOWN: u32 = 3;
const SATIN_PANE_DROP_CENTER: u32 = 0;
const SATIN_PANE_DROP_LEFT: u32 = 1;
const SATIN_PANE_DROP_RIGHT: u32 = 2;
const SATIN_PANE_DROP_TOP: u32 = 3;
const SATIN_PANE_DROP_BOTTOM: u32 = 4;

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_create() -> *mut TerminalCore {
    crate::logging::init();
    log::info!(target: "lifecycle", "core_created");
    Box::into_raw(Box::new(TerminalCore::new()))
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_create_with_theme(theme: *const c_char) -> *mut TerminalCore {
    crate::logging::init();
    let theme = c_string(theme).unwrap_or_else(|| "Graphite".to_owned());
    log::info!(target: "lifecycle", "core_created theme={theme}");
    Box::into_raw(Box::new(TerminalCore::new_with_theme(theme)))
}

#[unsafe(no_mangle)]
/// # Safety
///
/// `handle` must be either null or a pointer returned by `satin_core_create`.
/// Non-null handles must be passed to this function at most once.
pub unsafe extern "C" fn satin_core_destroy(handle: *mut TerminalCore) {
    if handle.is_null() {
        return;
    }

    // SAFETY: `handle` must come from `satin_core_create` and is consumed once here.
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_new_tab(handle: *mut TerminalCore) -> usize {
    let Some(core) = core_mut(handle) else {
        return usize::MAX;
    };
    core.new_tab()
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_split_active(handle: *mut TerminalCore, axis: u32) -> usize {
    let Some(core) = core_mut(handle) else {
        return usize::MAX;
    };
    let Some(axis) = split_axis(axis) else {
        return usize::MAX;
    };
    core.split_active(axis).unwrap_or(usize::MAX)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_resize_split(
    handle: *mut TerminalCore,
    first_pane_id: usize,
    second_pane_id: usize,
    ratio: f64,
) -> u8 {
    core_mut(handle).is_some_and(|core| core.resize_split(first_pane_id, second_pane_id, ratio))
        as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_close_pane(handle: *mut TerminalCore, pane_id: usize) -> u8 {
    core_mut(handle).is_some_and(|core| core.close_pane(pane_id)) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_move_pane(
    handle: *mut TerminalCore,
    source_pane_id: usize,
    target_pane_id: usize,
    position: u32,
) -> u8 {
    let Some(position) = pane_drop_position(position) else {
        return 0;
    };
    core_mut(handle).is_some_and(|core| core.move_pane(source_pane_id, target_pane_id, position))
        as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_select_tab(handle: *mut TerminalCore, index: usize) -> u8 {
    core_mut(handle).is_some_and(|core| core.select_tab(index)) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_move_tab(
    handle: *mut TerminalCore,
    tab_id: usize,
    index: usize,
) -> u8 {
    core_mut(handle).is_some_and(|core| core.move_tab(tab_id, index)) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_select_pane(handle: *mut TerminalCore, pane_id: usize) -> u8 {
    core_mut(handle).is_some_and(|core| core.select_pane(pane_id)) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_pane_in_direction(
    handle: *const TerminalCore,
    direction: u32,
) -> usize {
    let Some(core) = core_ref(handle) else {
        return usize::MAX;
    };
    pane_direction(direction)
        .and_then(|direction| core.pane_in_direction(direction))
        .unwrap_or(usize::MAX)
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_rename_tab(
    handle: *mut TerminalCore,
    index: usize,
    title: *const c_char,
) -> u8 {
    let Some(core) = core_mut(handle) else {
        return 0;
    };
    let Some(title) = c_string(title) else {
        return 0;
    };
    core.rename_tab(index, title) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_set_tab_theme(
    handle: *mut TerminalCore,
    index: usize,
    theme: *const c_char,
) -> u8 {
    let Some(core) = core_mut(handle) else {
        return 0;
    };
    let Some(theme) = c_string(theme) else {
        return 0;
    };
    core.set_tab_theme(index, theme) as u8
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_set_default_theme(
    handle: *mut TerminalCore,
    theme: *const c_char,
) -> u8 {
    let Some(core) = core_mut(handle) else {
        return 0;
    };
    let Some(theme) = c_string(theme) else {
        return 0;
    };
    core.set_default_theme(theme);
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_snapshot_json(handle: *const TerminalCore) -> *mut c_char {
    let Some(core) = core_ref(handle) else {
        return ptr::null_mut();
    };
    json_ptr(&core.snapshot())
}

#[unsafe(no_mangle)]
pub extern "C" fn satin_core_apply_workspace_json(
    handle: *mut TerminalCore,
    workspace: *const c_char,
) -> u8 {
    let Some(core) = core_mut(handle) else {
        return 0;
    };
    let Some(workspace) = c_string(workspace) else {
        return 0;
    };
    let Ok(workspace) = serde_json::from_str::<TerminalWorkspaceInput>(&workspace) else {
        return 0;
    };
    core.apply_workspace(workspace).is_ok() as u8
}

fn split_axis(axis: u32) -> Option<SplitAxis> {
    match axis {
        SATIN_SPLIT_VERTICAL => Some(SplitAxis::Vertical),
        SATIN_SPLIT_HORIZONTAL => Some(SplitAxis::Horizontal),
        _ => None,
    }
}

fn pane_direction(direction: u32) -> Option<PaneDirection> {
    match direction {
        SATIN_PANE_LEFT => Some(PaneDirection::Left),
        SATIN_PANE_RIGHT => Some(PaneDirection::Right),
        SATIN_PANE_UP => Some(PaneDirection::Up),
        SATIN_PANE_DOWN => Some(PaneDirection::Down),
        _ => None,
    }
}

fn pane_drop_position(position: u32) -> Option<PaneDropPosition> {
    match position {
        SATIN_PANE_DROP_CENTER => Some(PaneDropPosition::Center),
        SATIN_PANE_DROP_LEFT => Some(PaneDropPosition::Left),
        SATIN_PANE_DROP_RIGHT => Some(PaneDropPosition::Right),
        SATIN_PANE_DROP_TOP => Some(PaneDropPosition::Top),
        SATIN_PANE_DROP_BOTTOM => Some(PaneDropPosition::Bottom),
        _ => None,
    }
}

fn core_ref<'a>(handle: *const TerminalCore) -> Option<&'a TerminalCore> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an opaque pointer created by `satin_core_create`.
    unsafe { handle.as_ref() }
}

fn core_mut<'a>(handle: *mut TerminalCore) -> Option<&'a mut TerminalCore> {
    if handle.is_null() {
        return None;
    }

    // SAFETY: Callers pass an exclusive opaque pointer created by `satin_core_create`.
    unsafe { handle.as_mut() }
}
