//! Superwarm's engine: estimates the energy and carbon footprint of AI coding
//! agents (Claude Code, Codex, Antigravity) from the token counts in their local logs.
//!
//! The model and every coefficient are documented in docs/METHODOLOGY.md.

pub mod antigravity;
pub mod card;
pub mod catalog;
pub mod citations;
pub mod claude;
pub mod codex;
pub mod demo;
pub mod emissions;
pub mod equivalents;
pub mod format;
pub mod lines;
pub mod paths;
pub mod remote;
pub mod render;
pub mod report;
pub mod review;
pub mod scanner;
pub mod snapshot;
pub mod usage;
