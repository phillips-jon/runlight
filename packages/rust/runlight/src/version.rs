//! The SDK's version and the HTTP API's, as the TypeScript SDK's version.ts
//! has them.

/// The SDK's version.
pub const VERSION: &str = "0.1.0";

/// Bumped when the HTTP API changes shape, so the dashboard and the hub can tell.
pub const API_VERSION: u32 = 1;
