pub mod app;
mod layout;

pub use app::{TerminalCore, TerminalCoreSnapshot, TerminalWorkspaceInput};
pub use layout::{PaneLayoutInput, PaneLayoutSnapshot, SplitAxis};
