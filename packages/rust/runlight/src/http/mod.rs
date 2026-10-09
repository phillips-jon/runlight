//! The Fetch API's types, as the routes and everything that calls out use
//! them: `Request`, `Response`, `Headers`, `URL`, `URLSearchParams`, and an
//! injected `fetch`.

mod fetch;
mod headers;
mod request;
mod response;
mod search_params;
mod url;

pub use fetch::*;
pub use headers::Headers;
pub use request::{Request, utf8};
pub use response::Response;
pub use search_params::SearchParams;
pub use url::Url;
