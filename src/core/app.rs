use std::collections::HashSet;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

use super::layout::{
    MAX_SPLIT_RATIO, MIN_SPLIT_RATIO, PaneDirection, PaneId, PaneLayout, PaneLayoutInput,
    PaneLayoutSnapshot, SplitAxis,
};

const DEFAULT_THEME_NAME: &str = "Graphite";

#[derive(Clone, Debug, PartialEq)]
pub struct TerminalCore {
    tabs: Vec<TerminalCoreTab>,
    active_tab: usize,
    next_tab_id: usize,
    next_pane_id: usize,
    default_theme: String,
}

impl Default for TerminalCore {
    fn default() -> Self {
        Self::new_with_theme(DEFAULT_THEME_NAME)
    }
}

impl TerminalCore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn new_with_theme(theme: impl Into<String>) -> Self {
        let default_theme = normalized_theme(theme.into());
        let mut core = Self {
            tabs: Vec::new(),
            active_tab: 0,
            next_tab_id: 1,
            next_pane_id: 1,
            default_theme,
        };
        core.new_tab();
        core
    }

    pub fn new_tab(&mut self) -> usize {
        let tab_id = self.next_tab_id;
        self.next_tab_id += 1;
        let pane_id = self.alloc_pane_id();
        let theme = self.default_theme.clone();
        self.tabs.push(TerminalCoreTab::new(tab_id, pane_id, theme));
        self.active_tab = self.tabs.len() - 1;
        self.active_tab
    }

    pub fn split_active(&mut self, axis: SplitAxis) -> Option<usize> {
        let pane_id = self.alloc_pane_id();
        self.active_tab_mut()?.split_active(pane_id, axis);
        Some(pane_id.0)
    }

    pub fn resize_split(
        &mut self,
        first_pane_id: usize,
        second_pane_id: usize,
        ratio: f64,
    ) -> bool {
        if first_pane_id == second_pane_id
            || !ratio.is_finite()
            || !(MIN_SPLIT_RATIO..=MAX_SPLIT_RATIO).contains(&ratio)
        {
            return false;
        }
        let Some(tab) = self.active_tab_mut() else {
            return false;
        };
        tab.layout
            .set_split_ratio(PaneId(first_pane_id), PaneId(second_pane_id), ratio)
    }

    pub fn close_pane(&mut self, pane_id: usize) -> bool {
        let pane_id = PaneId(pane_id);
        let Some(tab_index) = self.tabs.iter().position(|tab| tab.contains_pane(pane_id)) else {
            return false;
        };
        if self.tabs[tab_index].pane_count() == 1 {
            self.tabs.remove(tab_index);
            self.select_neighbor_after_tab_close(tab_index);
            return true;
        }
        self.tabs[tab_index].close_pane(pane_id)
    }

    pub fn select_tab(&mut self, index: usize) -> bool {
        if index >= self.tabs.len() {
            return false;
        }
        self.active_tab = index;
        true
    }

    pub fn move_tab(&mut self, tab_id: usize, target_index: usize) -> bool {
        if target_index >= self.tabs.len() {
            return false;
        }
        let Some(source_index) = self.tab_index_for_id(tab_id) else {
            return false;
        };
        if source_index == target_index {
            return true;
        }
        let active_tab_id = self.tabs.get(self.active_tab).map(|tab| tab.id);
        let tab = self.tabs.remove(source_index);
        self.tabs.insert(target_index, tab);
        if let Some(active_tab_id) = active_tab_id {
            self.active_tab = self.tab_index_for_id(active_tab_id).unwrap_or(0);
        }
        true
    }

    pub fn select_pane(&mut self, pane_id: usize) -> bool {
        let pane_id = PaneId(pane_id);
        let Some(tab) = self.active_tab_mut() else {
            return false;
        };
        if !tab.contains_pane(pane_id) {
            return false;
        }
        tab.active_pane = pane_id;
        true
    }

    pub fn pane_in_direction(&self, direction: PaneDirection) -> Option<usize> {
        self.active_tab()
            .and_then(|tab| tab.layout.pane_in_direction(tab.active_pane, direction))
            .map(|pane_id| pane_id.0)
    }

    pub fn rename_tab(&mut self, index: usize, title: impl Into<String>) -> bool {
        let Some(tab) = self.tabs.get_mut(index) else {
            return false;
        };
        let title = title.into();
        if title.trim().is_empty() {
            return false;
        }
        tab.title = title;
        true
    }

    pub fn set_tab_theme(&mut self, index: usize, theme: impl Into<String>) -> bool {
        let Some(tab) = self.tabs.get_mut(index) else {
            return false;
        };
        tab.theme = normalized_theme(theme.into());
        true
    }

    pub fn set_default_theme(&mut self, theme: impl Into<String>) {
        self.default_theme = normalized_theme(theme.into());
    }

    pub fn tab_index_for_id(&self, tab_id: usize) -> Option<usize> {
        self.tabs.iter().position(|tab| tab.id == tab_id)
    }

    pub fn tab_id_for_pane(&self, pane_id: usize) -> Option<usize> {
        let pane_id = PaneId(pane_id);
        self.tabs
            .iter()
            .find(|tab| tab.contains_pane(pane_id))
            .map(|tab| tab.id)
    }

    pub fn snapshot(&self) -> TerminalCoreSnapshot {
        TerminalCoreSnapshot {
            active_tab: self.active_tab,
            tabs: self
                .tabs
                .iter()
                .enumerate()
                .map(|(index, tab)| tab.snapshot(index))
                .collect(),
        }
    }

    pub fn apply_workspace(&mut self, workspace: TerminalWorkspaceInput) -> Result<()> {
        if workspace.tabs.is_empty() || workspace.active_tab >= workspace.tabs.len() {
            bail!("workspace must contain an active tab");
        }
        let mut tab_ids = HashSet::new();
        let mut pane_ids = HashSet::new();
        let mut tabs = Vec::with_capacity(workspace.tabs.len());
        for tab in workspace.tabs {
            if !tab_ids.insert(tab.id) {
                bail!("workspace contains duplicate tab id {}", tab.id);
            }
            let layout = PaneLayout::from_input(tab.layout)?;
            let mut layout_panes = Vec::new();
            layout.leaves(&mut layout_panes);
            if layout_panes.is_empty() || !layout_panes.contains(&PaneId(tab.active_pane)) {
                bail!("workspace tab {} has no valid active pane", tab.id);
            }
            let mut unique_layout_panes = HashSet::new();
            for pane_id in &layout_panes {
                if !unique_layout_panes.insert(*pane_id) || !pane_ids.insert(*pane_id) {
                    bail!("workspace contains duplicate pane id {}", pane_id.0);
                }
            }
            let declared = tab.panes.into_iter().map(PaneId).collect::<HashSet<_>>();
            if declared != unique_layout_panes {
                bail!(
                    "workspace tab {} pane list does not match its layout",
                    tab.id
                );
            }
            tabs.push(TerminalCoreTab {
                id: tab.id,
                title: tab.title,
                active_pane: PaneId(tab.active_pane),
                theme: normalized_theme(tab.theme),
                panes: layout_panes,
                layout,
            });
        }
        self.active_tab = workspace.active_tab;
        self.next_tab_id = tab_ids.iter().max().copied().unwrap_or(0).saturating_add(1);
        self.next_pane_id = pane_ids
            .iter()
            .map(|pane| pane.0)
            .max()
            .unwrap_or(0)
            .saturating_add(1);
        self.tabs = tabs;
        Ok(())
    }

    fn active_tab_mut(&mut self) -> Option<&mut TerminalCoreTab> {
        self.tabs.get_mut(self.active_tab)
    }

    fn active_tab(&self) -> Option<&TerminalCoreTab> {
        self.tabs.get(self.active_tab)
    }

    fn alloc_pane_id(&mut self) -> PaneId {
        let id = PaneId(self.next_pane_id);
        self.next_pane_id += 1;
        id
    }

    fn select_neighbor_after_tab_close(&mut self, closed_index: usize) {
        if self.tabs.is_empty() {
            self.active_tab = 0;
        } else if closed_index < self.active_tab {
            self.active_tab -= 1;
        } else if self.active_tab >= self.tabs.len() {
            self.active_tab = self.tabs.len() - 1;
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct TerminalCoreTab {
    id: usize,
    title: String,
    active_pane: PaneId,
    theme: String,
    panes: Vec<PaneId>,
    layout: PaneLayout,
}

impl TerminalCoreTab {
    fn new(tab_id: usize, pane_id: PaneId, theme: String) -> Self {
        Self {
            id: tab_id,
            title: format!("session {tab_id}"),
            active_pane: pane_id,
            theme,
            panes: vec![pane_id],
            layout: PaneLayout::Leaf(pane_id),
        }
    }

    fn split_active(&mut self, pane_id: PaneId, axis: SplitAxis) {
        if self.layout.split_leaf(self.active_pane, pane_id, axis) {
            self.panes.push(pane_id);
            self.active_pane = pane_id;
        }
    }

    fn close_pane(&mut self, pane_id: PaneId) -> bool {
        if self.pane_count() <= 1 || !self.contains_pane(pane_id) {
            return false;
        }
        let Some(layout) = self.layout.clone().without_leaf(pane_id) else {
            return false;
        };
        self.layout = layout;
        self.panes.retain(|id| *id != pane_id);
        if self.active_pane == pane_id {
            self.active_pane = self.layout.first_leaf().unwrap_or(self.panes[0]);
        }
        true
    }

    fn contains_pane(&self, pane_id: PaneId) -> bool {
        self.panes.contains(&pane_id)
    }

    fn pane_count(&self) -> usize {
        self.panes.len()
    }

    fn snapshot(&self, index: usize) -> TerminalCoreTabSnapshot {
        TerminalCoreTabSnapshot {
            id: self.id,
            index,
            title: self.title.clone(),
            active_pane: self.active_pane.0,
            theme: self.theme.clone(),
            panes: self.panes.iter().map(|pane| pane.0).collect(),
            layout: self.layout.snapshot(),
        }
    }
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct TerminalCoreSnapshot {
    pub active_tab: usize,
    pub tabs: Vec<TerminalCoreTabSnapshot>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct TerminalCoreTabSnapshot {
    pub id: usize,
    pub index: usize,
    pub title: String,
    pub active_pane: usize,
    pub theme: String,
    pub panes: Vec<usize>,
    pub layout: PaneLayoutSnapshot,
}

#[derive(Clone, Debug, Deserialize)]
pub struct TerminalWorkspaceInput {
    pub active_tab: usize,
    pub tabs: Vec<TerminalWorkspaceTabInput>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct TerminalWorkspaceTabInput {
    pub id: usize,
    pub title: String,
    pub active_pane: usize,
    pub theme: String,
    pub panes: Vec<usize>,
    pub layout: PaneLayoutInput,
}

fn normalized_theme(theme: String) -> String {
    let theme = theme.trim();
    if theme.is_empty() {
        DEFAULT_THEME_NAME.to_owned()
    } else {
        theme.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_core_starts_with_one_session_tab() {
        let snapshot = TerminalCore::new().snapshot();

        assert_eq!(snapshot.active_tab, 0);
        assert_eq!(snapshot.tabs[0].id, 1);
        assert_eq!(snapshot.tabs[0].title, "session 1");
        assert_eq!(snapshot.tabs[0].active_pane, 1);
    }

    #[test]
    fn configured_default_theme_applies_to_new_tabs() {
        let mut core = TerminalCore::new_with_theme("Harbor");
        assert_eq!(core.snapshot().tabs[0].theme, "Harbor");

        core.set_tab_theme(0, "Rose");
        core.new_tab();
        assert_eq!(core.snapshot().tabs[1].theme, "Harbor");

        core.set_default_theme("Paper");
        core.new_tab();
        assert_eq!(core.snapshot().tabs[2].theme, "Paper");
    }

    #[test]
    fn stable_tab_ids_resolve_panes() {
        let mut core = TerminalCore::new();
        assert_eq!(core.new_tab(), 1);
        assert_eq!(core.split_active(SplitAxis::Vertical), Some(3));

        assert_eq!(core.tab_index_for_id(2), Some(1));
        assert_eq!(core.tab_id_for_pane(3), Some(2));
        assert_eq!(core.tab_id_for_pane(99), None);
    }

    #[test]
    fn splitting_active_pane_selects_the_new_pane() {
        let mut core = TerminalCore::new();

        assert_eq!(core.split_active(SplitAxis::Vertical), Some(2));
        let snapshot = core.snapshot();
        assert_eq!(snapshot.tabs[0].active_pane, 2);
        assert_eq!(
            serde_json::to_value(&snapshot.tabs[0].layout).unwrap(),
            serde_json::json!({
                "kind": "split",
                "axis": "vertical",
                "ratio": 0.5,
                "first": {"kind": "leaf", "pane_id": 1},
                "second": {"kind": "leaf", "pane_id": 2}
            })
        );
    }

    #[test]
    fn resizing_a_nested_split_updates_only_the_marked_boundary() {
        let mut core = TerminalCore::new();
        assert_eq!(core.split_active(SplitAxis::Vertical), Some(2));
        assert_eq!(core.split_active(SplitAxis::Horizontal), Some(3));

        assert!(core.resize_split(2, 3, 0.7));
        let snapshot = core.snapshot();
        let root = &snapshot.tabs[0].layout;
        assert_eq!(root.ratio, Some(0.5));
        assert_eq!(
            root.second.as_ref().and_then(|layout| layout.ratio),
            Some(0.7)
        );

        assert!(core.resize_split(1, 2, 0.35));
        assert_eq!(core.snapshot().tabs[0].layout.ratio, Some(0.35));
    }

    #[test]
    fn resizing_a_split_rejects_invalid_markers_and_ratios() {
        let mut core = TerminalCore::new();
        assert_eq!(core.split_active(SplitAxis::Vertical), Some(2));
        let before = core.snapshot();

        assert!(!core.resize_split(1, 99, 0.4));
        assert!(!core.resize_split(1, 2, f64::NAN));
        assert!(!core.resize_split(1, 2, 0.01));
        assert_eq!(core.snapshot(), before);
    }

    #[test]
    fn selecting_a_visible_split_pane_updates_focus() {
        let mut core = TerminalCore::new();
        assert_eq!(core.split_active(SplitAxis::Horizontal), Some(2));

        assert!(core.select_pane(1));
        assert_eq!(core.snapshot().tabs[0].active_pane, 1);
        assert!(!core.select_pane(99));
        assert_eq!(core.snapshot().tabs[0].active_pane, 1);
    }

    #[test]
    fn finds_neighboring_panes_in_a_grid_without_wrapping() {
        let mut core = TerminalCore::new();
        assert_eq!(core.split_active(SplitAxis::Vertical), Some(2));
        assert!(core.select_pane(1));
        assert_eq!(core.split_active(SplitAxis::Horizontal), Some(3));
        assert!(core.select_pane(2));
        assert_eq!(core.split_active(SplitAxis::Horizontal), Some(4));

        assert!(core.select_pane(1));
        assert_eq!(core.pane_in_direction(PaneDirection::Left), None);
        assert_eq!(core.pane_in_direction(PaneDirection::Up), None);
        assert_eq!(core.pane_in_direction(PaneDirection::Right), Some(2));
        assert_eq!(core.pane_in_direction(PaneDirection::Down), Some(3));

        assert!(core.select_pane(4));
        assert_eq!(core.pane_in_direction(PaneDirection::Left), Some(3));
        assert_eq!(core.pane_in_direction(PaneDirection::Up), Some(2));
        assert_eq!(core.pane_in_direction(PaneDirection::Right), None);
        assert_eq!(core.pane_in_direction(PaneDirection::Down), None);
    }

    #[test]
    fn chooses_the_nearest_aligned_pane_in_an_unbalanced_layout() {
        let mut core = TerminalCore::new();
        assert_eq!(core.split_active(SplitAxis::Vertical), Some(2));
        assert_eq!(core.split_active(SplitAxis::Horizontal), Some(3));

        assert!(core.select_pane(1));
        assert_eq!(core.pane_in_direction(PaneDirection::Right), Some(2));
        assert!(core.select_pane(2));
        assert_eq!(core.pane_in_direction(PaneDirection::Down), Some(3));
        assert!(core.select_pane(3));
        assert_eq!(core.pane_in_direction(PaneDirection::Left), Some(1));
        assert_eq!(core.pane_in_direction(PaneDirection::Up), Some(2));
    }

    #[test]
    fn closing_split_pane_selects_the_remaining_pane() {
        let mut core = TerminalCore::new();
        assert_eq!(core.split_active(SplitAxis::Vertical), Some(2));

        assert!(core.close_pane(2));
        assert_eq!(core.snapshot().tabs[0].active_pane, 1);
    }

    #[test]
    fn closing_last_pane_removes_tab_and_selects_neighbor() {
        let mut core = TerminalCore::new();
        assert_eq!(core.new_tab(), 1);

        assert!(core.close_pane(2));
        let snapshot = core.snapshot();

        assert_eq!(snapshot.tabs.len(), 1);
        assert_eq!(snapshot.active_tab, 0);
        assert_eq!(snapshot.tabs[0].active_pane, 1);
    }

    #[test]
    fn moving_a_tab_preserves_the_active_tab_identity() {
        let mut core = TerminalCore::new();
        core.new_tab();
        core.new_tab();

        assert!(core.move_tab(1, 2));
        let snapshot = core.snapshot();

        assert_eq!(
            snapshot.tabs.iter().map(|tab| tab.id).collect::<Vec<_>>(),
            vec![2, 3, 1]
        );
        assert_eq!(snapshot.tabs[snapshot.active_tab].id, 3);
    }

    #[test]
    fn moving_a_tab_rejects_unknown_ids_and_out_of_range_indexes() {
        let mut core = TerminalCore::new();
        core.new_tab();
        let before = core.snapshot();

        assert!(!core.move_tab(99, 0));
        assert!(!core.move_tab(1, 2));
        assert_eq!(core.snapshot(), before);
    }

    #[test]
    fn applies_validated_external_workspace_with_retained_ratio() {
        let mut core = TerminalCore::new();
        core.apply_workspace(TerminalWorkspaceInput {
            active_tab: 0,
            tabs: vec![TerminalWorkspaceTabInput {
                id: 90,
                title: "tmux".to_owned(),
                active_pane: 902,
                theme: "Harbor".to_owned(),
                panes: vec![901, 902],
                layout: PaneLayoutInput {
                    kind: "split".to_owned(),
                    pane_id: None,
                    axis: Some(SplitAxis::Vertical),
                    ratio: Some(0.4),
                    first: Some(Box::new(PaneLayoutInput {
                        kind: "leaf".to_owned(),
                        pane_id: Some(901),
                        axis: None,
                        ratio: None,
                        first: None,
                        second: None,
                    })),
                    second: Some(Box::new(PaneLayoutInput {
                        kind: "leaf".to_owned(),
                        pane_id: Some(902),
                        axis: None,
                        ratio: None,
                        first: None,
                        second: None,
                    })),
                },
            }],
        })
        .unwrap();

        let snapshot = core.snapshot();
        assert_eq!(snapshot.tabs[0].id, 90);
        assert_eq!(snapshot.tabs[0].layout.ratio, Some(0.4));
    }
}
