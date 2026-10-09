//! What can go wrong in Runlight's own work.

use crate::goals::CodedError;
use crate::store::DbError;

/// An error from Runlight: a database that failed, or something refused with a code the dashboard
/// says in its own words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// The database failed.
    Db(DbError),
    /// A setting refused (the SDK's SettingsError, a RangeError).
    Settings(CodedError),
    /// The mail service refused, or is not set up (MailError).
    Mail(CodedError),
    /// A short link that cannot be made (LinkError).
    Link(CodedError),
    /// Something asked for that is not there (the SDK's plain RangeError, such as "Unknown link").
    Range(String),
    /// Anything else, with its message.
    Other(String),
}

impl Error {
    /// The English message.
    pub fn message(&self) -> &str {
        match self {
            Error::Db(e) => &e.0,
            Error::Settings(e) | Error::Mail(e) | Error::Link(e) => &e.message,
            Error::Range(m) | Error::Other(m) => m,
        }
    }

    /// The code and params of an error that carries them.
    pub fn coded(&self) -> Option<&CodedError> {
        match self {
            Error::Settings(e) | Error::Mail(e) | Error::Link(e) => Some(e),
            _ => None,
        }
    }

    /// A SettingsError.
    pub fn settings(message: impl Into<String>, code: &str, params: &[(&str, &str)]) -> Error {
        Error::Settings(CodedError::new(message, code, params))
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for Error {}

impl From<DbError> for Error {
    fn from(e: DbError) -> Error {
        Error::Db(e)
    }
}
