//! Runlight: privacy friendly web analytics that lives inside your app.
//!
//! This crate is the Rust version of Runlight, a port of the TypeScript SDK
//! that answers every request the way it does and uses the same tables, so
//! either one can read the other's database.

#![forbid(unsafe_code)]

use std::future::Future;
use std::pin::Pin;

pub mod accounts;
pub mod assets;
pub mod assistant;
pub mod brand;
pub mod data;
mod error;
pub use error::Error;
pub mod funnels;
pub mod geo;
pub mod goals;
pub mod hash;
pub mod http;
pub mod icon;
pub mod intl;
pub mod journeys;
pub mod js;
pub mod limit;
pub mod links;
pub mod mail;
pub mod mcp;
pub mod messages;
pub mod mmdb;
pub mod payload;
pub mod query;
pub mod routes;
pub mod runlight;
mod runlight_settings;
pub use runlight::{Runlight, RunlightOptions, SiteOptions, TrustProxy};
pub use routes::{Routes, RoutesOptions, TokenOption};
pub(crate) mod re;
pub mod reports;
pub mod safefetch;
pub mod sources;
pub mod store;
pub mod time;
pub mod ua;
pub mod version;
pub mod zip;

/// A boxed future that can be sent between threads, as the crate's traits
/// return.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Any error, boxed.
pub type BoxError = Box<dyn std::error::Error + Send + Sync>;
