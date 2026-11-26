//! Superwarm's engine: estimates the energy and carbon footprint of AI coding
//! agents (Claude Code, Codex) from the token counts in their local logs.
//!
//! The model and every coefficient are documented in docs/METHODOLOGY.md.

pub mod catalog;
pub mod citations;
pub mod claude;
pub mod codex;
pub mod emissions;
pub mod equivalents;
pub mod format;
pub mod lines;
pub mod scanner;
pub mod usage;
