use serde::Serialize;

use super::layout::{PaneId, PaneLayout, PaneLayoutSnapshot, SplitAxis};

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

    fn active_tab_mut(&mut self) -> Option<&mut TerminalCoreTab> {
        self.tabs.get_mut(self.active_tab)
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
                "first": {"kind": "leaf", "pane_id": 1},
                "second": {"kind": "leaf", "pane_id": 2}
            })
        );
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
}
