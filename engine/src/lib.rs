//! Superwarm's engine: estimates the energy and carbon footprint of AI coding
//! agents (Claude Code, Codex) from the token counts in their local logs.
//!
//! The model and every coefficient are documented in docs/METHODOLOGY.md.

pub mod claude;
pub mod codex;
pub mod lines;
pub mod usage;
