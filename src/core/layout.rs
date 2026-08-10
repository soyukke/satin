use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) struct PaneId(pub usize);

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitAxis {
    Vertical,
    Horizontal,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct PaneLayoutSnapshot {
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_id: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub axis: Option<SplitAxis>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ratio: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first: Option<Box<PaneLayoutSnapshot>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub second: Option<Box<PaneLayoutSnapshot>>,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum PaneLayout {
    Leaf(PaneId),
    Split {
        axis: SplitAxis,
        ratio: f64,
        first: Box<PaneLayout>,
        second: Box<PaneLayout>,
    },
}

impl PaneLayout {
    pub(crate) fn snapshot(&self) -> PaneLayoutSnapshot {
        match self {
            Self::Leaf(pane_id) => PaneLayoutSnapshot {
                kind: "leaf",
                pane_id: Some(pane_id.0),
                axis: None,
                ratio: None,
                first: None,
                second: None,
            },
            Self::Split {
                axis,
                ratio,
                first,
                second,
            } => PaneLayoutSnapshot {
                kind: "split",
                pane_id: None,
                axis: Some(*axis),
                ratio: Some(*ratio),
                first: Some(Box::new(first.snapshot())),
                second: Some(Box::new(second.snapshot())),
            },
        }
    }

    pub(crate) fn split_leaf(&mut self, target: PaneId, new_pane: PaneId, axis: SplitAxis) -> bool {
        match self {
            Self::Leaf(id) if *id == target => {
                *self = Self::Split {
                    axis,
                    ratio: 0.5,
                    first: Box::new(Self::Leaf(*id)),
                    second: Box::new(Self::Leaf(new_pane)),
                };
                true
            }
            Self::Leaf(_) => false,
            Self::Split { first, second, .. } => {
                first.split_leaf(target, new_pane, axis)
                    || second.split_leaf(target, new_pane, axis)
            }
        }
    }

    pub(crate) fn without_leaf(self, target: PaneId) -> Option<Self> {
        match self {
            Self::Leaf(id) if id == target => None,
            Self::Leaf(id) => Some(Self::Leaf(id)),
            Self::Split {
                axis,
                ratio,
                first,
                second,
            } => match (first.without_leaf(target), second.without_leaf(target)) {
                (Some(first), Some(second)) => Some(Self::Split {
                    axis,
                    ratio,
                    first: Box::new(first),
                    second: Box::new(second),
                }),
                (Some(layout), None) | (None, Some(layout)) => Some(layout),
                (None, None) => None,
            },
        }
    }

    pub(crate) fn from_input(input: PaneLayoutInput) -> Result<Self> {
        match input.kind.as_str() {
            "leaf" => {
                let Some(pane_id) = input.pane_id else {
                    bail!("leaf layout omitted pane_id");
                };
                Ok(Self::Leaf(PaneId(pane_id)))
            }
            "split" => {
                let Some(axis) = input.axis else {
                    bail!("split layout omitted axis");
                };
                let Some(first) = input.first else {
                    bail!("split layout omitted first child");
                };
                let Some(second) = input.second else {
                    bail!("split layout omitted second child");
                };
                let ratio = input.ratio.unwrap_or(0.5);
                if !ratio.is_finite() || !(0.05..=0.95).contains(&ratio) {
                    bail!("split ratio must be finite and between 0.05 and 0.95");
                }
                Ok(Self::Split {
                    axis,
                    ratio,
                    first: Box::new(Self::from_input(*first)?),
                    second: Box::new(Self::from_input(*second)?),
                })
            }
            kind => bail!("unknown pane layout kind {kind:?}"),
        }
    }

    pub(crate) fn leaves(&self, output: &mut Vec<PaneId>) {
        match self {
            Self::Leaf(pane_id) => output.push(*pane_id),
            Self::Split { first, second, .. } => {
                first.leaves(output);
                second.leaves(output);
            }
        }
    }

    pub(crate) fn first_leaf(&self) -> Option<PaneId> {
        match self {
            Self::Leaf(id) => Some(*id),
            Self::Split { first, .. } => first.first_leaf(),
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct PaneLayoutInput {
    pub kind: String,
    pub pane_id: Option<usize>,
    pub axis: Option<SplitAxis>,
    pub ratio: Option<f64>,
    pub first: Option<Box<PaneLayoutInput>>,
    pub second: Option<Box<PaneLayoutInput>>,
}
