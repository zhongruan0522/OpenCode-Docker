use std::{collections::HashSet, env, path::PathBuf, sync::Arc};

use axum::http::{header, HeaderMap, HeaderValue};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rand::{rngs::OsRng, RngCore};
use subtle::ConstantTimeEq;
use tokio::sync::Mutex;

use crate::{
    error::{Result, ServiceError},
    url_utils,
};

const SESSION_COOKIE: &str = "opencode_manager_session";

/// Shared application state for auth, session storage, and config file paths.
#[derive(Clone)]
pub struct AppState {
    username: Arc<String>,
    password: Arc<String>,
    sessions: Arc<Mutex<HashSet<String>>>,
    pub(crate) paths: Arc<ConfigPaths>,
}

#[derive(Debug)]
pub(crate) struct ConfigPaths {
    pub opencode_config: PathBuf,
    pub codex_config: PathBuf,
    pub codex_auth: PathBuf,
}

impl AppState {
    pub fn from_env() -> Result<Self> {
        let username = required_env("OPENCODE_SERVER_USERNAME")?;
        let password = required_env("OPENCODE_SERVER_PASSWORD")?;
        let home = env::var("HOME").unwrap_or_else(|_| "/home/app".to_string());

        Ok(Self::new(username, password, ConfigPaths::from_home(home)))
    }

    pub(crate) fn new(username: String, password: String, paths: ConfigPaths) -> Self {
        Self {
            username: Arc::new(username),
            password: Arc::new(password),
            sessions: Arc::new(Mutex::new(HashSet::new())),
            paths: Arc::new(paths),
        }
    }

    pub(crate) fn credentials_match(&self, username: &str, password: &str) -> bool {
        constant_time_eq(username, &self.username) && constant_time_eq(password, &self.password)
    }

    pub(crate) async fn create_session_cookie(&self) -> HeaderValue {
        let mut bytes = [0u8; 32];
        OsRng.fill_bytes(&mut bytes);
        let token = URL_SAFE_NO_PAD.encode(bytes);
        self.sessions.lock().await.insert(token.clone());

        HeaderValue::from_str(&format!(
            "{SESSION_COOKIE}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200"
        ))
        .expect("session cookie is ASCII")
    }

    pub(crate) async fn clear_session_cookie(&self, headers: &HeaderMap) -> HeaderValue {
        if let Some(token) = session_token(headers) {
            self.sessions.lock().await.remove(&token);
        }

        HeaderValue::from_static(
            "opencode_manager_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0",
        )
    }

    pub(crate) async fn require_auth(&self, headers: &HeaderMap) -> Result<()> {
        let token = session_token(headers).ok_or(ServiceError::Unauthorized)?;
        if self.sessions.lock().await.contains(&token) {
            Ok(())
        } else {
            Err(ServiceError::Unauthorized)
        }
    }
}

impl ConfigPaths {
    pub(crate) fn from_home(home: impl Into<PathBuf>) -> Self {
        let home = home.into();
        Self {
            opencode_config: home.join(".config/opencode/opencode.json"),
            codex_config: home.join(".codex/config.toml"),
            codex_auth: home.join(".codex/auth.json"),
        }
    }
}

pub(crate) fn require_same_origin(headers: &HeaderMap) -> Result<()> {
    let host = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .ok_or_else(|| ServiceError::BadRequest("missing Host header".to_string()))?;

    if let Some(origin) = headers.get(header::ORIGIN).and_then(|value| value.to_str().ok()) {
        return url_utils::require_same_origin(origin, host);
    }

    if let Some(referer) = headers
        .get(header::REFERER)
        .and_then(|value| value.to_str().ok())
    {
        return url_utils::require_same_origin(referer, host);
    }

    Ok(())
}

fn required_env(name: &str) -> Result<String> {
    let value = env::var(name).map_err(|_| ServiceError::Config(format!("missing {name}")))?;
    if value.is_empty() {
        return Err(ServiceError::Config(format!("{name} must not be empty")));
    }

    Ok(value)
}

fn constant_time_eq(left: &str, right: &str) -> bool {
    left.len() == right.len() && left.as_bytes().ct_eq(right.as_bytes()).into()
}

fn session_token(headers: &HeaderMap) -> Option<String> {
    let raw = headers.get(header::COOKIE)?.to_str().ok()?;
    raw.split(';')
        .filter_map(|part| part.trim().split_once('='))
        .find_map(|(name, value)| (name == SESSION_COOKIE).then(|| value.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_cross_origin_request() {
        let mut headers = HeaderMap::new();
        headers.insert(header::HOST, HeaderValue::from_static("localhost:4098"));
        headers.insert(header::ORIGIN, HeaderValue::from_static("http://evil.test"));

        assert!(matches!(require_same_origin(&headers), Err(ServiceError::Forbidden)));
    }

    #[test]
    fn accepts_same_origin_request() {
        let mut headers = HeaderMap::new();
        headers.insert(header::HOST, HeaderValue::from_static("localhost:4098"));
        headers.insert(
            header::ORIGIN,
            HeaderValue::from_static("http://localhost:4098"),
        );

        assert!(require_same_origin(&headers).is_ok());
    }
}
