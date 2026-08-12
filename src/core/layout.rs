use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

pub(crate) const MIN_SPLIT_RATIO: f64 = 0.05;
pub(crate) const MAX_SPLIT_RATIO: f64 = 0.95;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) struct PaneId(pub usize);

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitAxis {
    Vertical,
    Horizontal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PaneDirection {
    Left,
    Right,
    Up,
    Down,
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

    pub(crate) fn set_split_ratio(
        &mut self,
        first_marker: PaneId,
        second_marker: PaneId,
        new_ratio: f64,
    ) -> bool {
        let Self::Split {
            ratio,
            first,
            second,
            ..
        } = self
        else {
            return false;
        };
        if first.contains_leaf(first_marker) && second.contains_leaf(second_marker) {
            *ratio = new_ratio;
            return true;
        }
        first.set_split_ratio(first_marker, second_marker, new_ratio)
            || second.set_split_ratio(first_marker, second_marker, new_ratio)
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
                if !ratio.is_finite() || !(MIN_SPLIT_RATIO..=MAX_SPLIT_RATIO).contains(&ratio) {
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

    pub(crate) fn pane_in_direction(
        &self,
        active_pane: PaneId,
        direction: PaneDirection,
    ) -> Option<PaneId> {
        let mut pane_rects = Vec::new();
        self.collect_pane_rects(PaneRect::unit(), &mut pane_rects);
        let active_rect = pane_rects
            .iter()
            .find_map(|(pane_id, rect)| (*pane_id == active_pane).then_some(*rect))?;

        pane_rects
            .into_iter()
            .filter(|(pane_id, _)| *pane_id != active_pane)
            .filter_map(|(pane_id, rect)| PaneCandidate::new(pane_id, rect, active_rect, direction))
            .min_by(PaneCandidate::compare)
            .map(|candidate| candidate.pane_id)
    }

    fn collect_pane_rects(&self, rect: PaneRect, output: &mut Vec<(PaneId, PaneRect)>) {
        match self {
            Self::Leaf(pane_id) => output.push((*pane_id, rect)),
            Self::Split {
                axis,
                ratio,
                first,
                second,
            } => {
                let (first_rect, second_rect) = rect.split(*axis, *ratio);
                first.collect_pane_rects(first_rect, output);
                second.collect_pane_rects(second_rect, output);
            }
        }
    }

    fn contains_leaf(&self, target: PaneId) -> bool {
        match self {
            Self::Leaf(id) => *id == target,
            Self::Split { first, second, .. } => {
                first.contains_leaf(target) || second.contains_leaf(target)
            }
        }
    }
}

#[derive(Clone, Copy)]
struct PaneRect {
    min_x: f64,
    max_x: f64,
    min_y: f64,
    max_y: f64,
}

impl PaneRect {
    fn unit() -> Self {
        Self {
            min_x: 0.0,
            max_x: 1.0,
            min_y: 0.0,
            max_y: 1.0,
        }
    }

    fn split(self, axis: SplitAxis, ratio: f64) -> (Self, Self) {
        match axis {
            SplitAxis::Vertical => {
                let boundary = self.min_x + (self.max_x - self.min_x) * ratio;
                (
                    Self {
                        max_x: boundary,
                        ..self
                    },
                    Self {
                        min_x: boundary,
                        ..self
                    },
                )
            }
            SplitAxis::Horizontal => {
                let boundary = self.min_y + (self.max_y - self.min_y) * ratio;
                (
                    Self {
                        max_y: boundary,
                        ..self
                    },
                    Self {
                        min_y: boundary,
                        ..self
                    },
                )
            }
        }
    }

    fn mid_x(self) -> f64 {
        (self.min_x + self.max_x) / 2.0
    }

    fn mid_y(self) -> f64 {
        (self.min_y + self.max_y) / 2.0
    }
}

struct PaneCandidate {
    pane_id: PaneId,
    primary_gap: f64,
    orthogonal_gap: f64,
    orthogonal_center_distance: f64,
}

impl PaneCandidate {
    fn new(
        pane_id: PaneId,
        rect: PaneRect,
        active_rect: PaneRect,
        direction: PaneDirection,
    ) -> Option<Self> {
        let (forward, primary_gap, orthogonal_gap, orthogonal_center_distance) = match direction {
            PaneDirection::Left => (
                active_rect.mid_x() - rect.mid_x(),
                active_rect.min_x - rect.max_x,
                interval_gap(active_rect.min_y, active_rect.max_y, rect.min_y, rect.max_y),
                (active_rect.mid_y() - rect.mid_y()).abs(),
            ),
            PaneDirection::Right => (
                rect.mid_x() - active_rect.mid_x(),
                rect.min_x - active_rect.max_x,
                interval_gap(active_rect.min_y, active_rect.max_y, rect.min_y, rect.max_y),
                (active_rect.mid_y() - rect.mid_y()).abs(),
            ),
            PaneDirection::Up => (
                active_rect.mid_y() - rect.mid_y(),
                active_rect.min_y - rect.max_y,
                interval_gap(active_rect.min_x, active_rect.max_x, rect.min_x, rect.max_x),
                (active_rect.mid_x() - rect.mid_x()).abs(),
            ),
            PaneDirection::Down => (
                rect.mid_y() - active_rect.mid_y(),
                rect.min_y - active_rect.max_y,
                interval_gap(active_rect.min_x, active_rect.max_x, rect.min_x, rect.max_x),
                (active_rect.mid_x() - rect.mid_x()).abs(),
            ),
        };
        (forward > f64::EPSILON).then_some(Self {
            pane_id,
            primary_gap: primary_gap.max(0.0),
            orthogonal_gap,
            orthogonal_center_distance,
        })
    }

    fn compare(&self, other: &Self) -> Ordering {
        metric_order(self.primary_gap, other.primary_gap)
            .then_with(|| metric_order(self.orthogonal_gap, other.orthogonal_gap))
            .then_with(|| {
                metric_order(
                    self.orthogonal_center_distance,
                    other.orthogonal_center_distance,
                )
            })
            .then_with(|| self.pane_id.0.cmp(&other.pane_id.0))
    }
}

fn interval_gap(first_min: f64, first_max: f64, second_min: f64, second_max: f64) -> f64 {
    (first_min.max(second_min) - first_max.min(second_max)).max(0.0)
}

fn metric_order(first: f64, second: f64) -> Ordering {
    if (first - second).abs() <= f64::EPSILON {
        Ordering::Equal
    } else {
        first.total_cmp(&second)
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
