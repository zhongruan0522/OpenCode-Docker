use std::{io, path::PathBuf};

use axum::{http::StatusCode, response::IntoResponse, Json};
use serde::Serialize;
use thiserror::Error;

/// Error type returned by the manager service HTTP handlers and startup path.
#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("forbidden")]
    Forbidden,
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("configuration error: {0}")]
    Config(String),
    #[error("I/O error at {path}: {source}")]
    Io { path: PathBuf, source: io::Error },
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("TOML error: {0}")]
    Toml(String),
    #[error("command failed: {0}")]
    Command(String),
}

#[derive(Serialize)]
struct ErrorBody {
    error: String,
}

impl ServiceError {
    pub(crate) fn io(path: impl Into<PathBuf>, source: io::Error) -> Self {
        Self::Io {
            path: path.into(),
            source,
        }
    }

    fn status(&self) -> StatusCode {
        match self {
            Self::Unauthorized => StatusCode::UNAUTHORIZED,
            Self::Forbidden => StatusCode::FORBIDDEN,
            Self::BadRequest(_) | Self::Toml(_) => StatusCode::BAD_REQUEST,
            Self::Config(_) | Self::Io { .. } | Self::Json(_) | Self::Command(_) => {
                StatusCode::INTERNAL_SERVER_ERROR
            }
        }
    }
}

impl IntoResponse for ServiceError {
    fn into_response(self) -> axum::response::Response {
        let status = self.status();
        let body = Json(ErrorBody {
            error: self.to_string(),
        });
        (status, [("Cache-Control", "no-store")], body).into_response()
    }
}

pub(crate) type Result<T> = std::result::Result<T, ServiceError>;
