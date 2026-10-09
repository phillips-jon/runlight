//! Mail: the services Runlight sends reports through (Amazon SES, SMTP, the
//! HTTP ones, and a webhook), and the sealing of the keys kept for them.

pub mod secret;
pub mod ses;
pub mod smtp;
pub mod transports;

pub use secret::{seal, unseal};
pub use transports::{
    MailConfig, MailError, Message, SERVICES, Service, ServiceField, check_config, send, service_message,
};
