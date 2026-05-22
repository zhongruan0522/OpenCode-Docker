use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use tokio::process::Command;

use crate::{
    auth::{require_same_origin, AppState},
    config_files,
    error::{Result, ServiceError},
    models::{
        ActiveCodexProviderRequest, ActiveModelRequest, LoginRequest, ManagedServiceStatus,
        McpServerRequest, MessageResponse, OpenCodeProviderRequest, SessionResponse,
    },
};

const MANAGED_PROGRAMS: [&str; 2] = ["opencode", "code-server"];

pub(crate) async fn login(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<LoginRequest>,
) -> Result<impl IntoResponse> {
    require_same_origin(&headers)?;
    if !state.credentials_match(&payload.username, &payload.password) {
        return Err(ServiceError::Unauthorized);
    }

    let cookie = state.create_session_cookie().await;
    Ok((
        StatusCode::OK,
        [(header::SET_COOKIE, cookie)],
        Json(SessionResponse {
            authenticated: true,
        }),
    ))
}

pub(crate) async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse> {
    require_same_origin(&headers)?;
    let cookie = state.clear_session_cookie(&headers).await;
    Ok((
        StatusCode::OK,
        [(header::SET_COOKIE, cookie)],
        Json(SessionResponse {
            authenticated: false,
        }),
    ))
}

pub(crate) async fn session(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<SessionResponse>> {
    let authenticated = state.require_auth(&headers).await.is_ok();
    Ok(Json(SessionResponse { authenticated }))
}

pub(crate) async fn config(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse> {
    state.require_auth(&headers).await?;
    Ok(Json(config_files::load_config(&state.paths)?))
}

pub(crate) async fn upsert_opencode_provider(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(payload): Json<OpenCodeProviderRequest>,
) -> Result<impl IntoResponse> {
    require_authenticated_write(&state, &headers).await?;
    config_files::upsert_opencode_provider(&state.paths, &id, payload)?;
    Ok(Json(MessageResponse {
        message: "OpenCode provider saved".to_string(),
    }))
}

pub(crate) async fn delete_opencode_provider(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<impl IntoResponse> {
    require_authenticated_write(&state, &headers).await?;
    config_files::delete_opencode_provider(&state.paths, &id)?;
    Ok(Json(MessageResponse {
        message: "OpenCode provider deleted".to_string(),
    }))
}

pub(crate) async fn set_opencode_active_model(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ActiveModelRequest>,
) -> Result<impl IntoResponse> {
    require_authenticated_write(&state, &headers).await?;
    config_files::set_opencode_active_model(&state.paths, payload)?;
    Ok(Json(MessageResponse {
        message: "OpenCode active model updated".to_string(),
    }))
}

pub(crate) async fn upsert_codex_provider(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(payload): Json<crate::models::CodexProviderRequest>,
) -> Result<impl IntoResponse> {
    require_authenticated_write(&state, &headers).await?;
    config_files::upsert_codex_provider(&state.paths, &id, payload)?;
    Ok(Json(MessageResponse {
        message: "Codex provider saved".to_string(),
    }))
}

pub(crate) async fn delete_codex_provider(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<impl IntoResponse> {
    require_authenticated_write(&state, &headers).await?;
    config_files::delete_codex_provider(&state.paths, &id)?;
    Ok(Json(MessageResponse {
        message: "Codex provider deleted".to_string(),
    }))
}

pub(crate) async fn set_codex_active_provider(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ActiveCodexProviderRequest>,
) -> Result<impl IntoResponse> {
    require_authenticated_write(&state, &headers).await?;
    config_files::set_codex_active_provider(&state.paths, payload)?;
    Ok(Json(MessageResponse {
        message: "Codex active provider updated".to_string(),
    }))
}

pub(crate) async fn upsert_mcp_server(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((app, id)): Path<(String, String)>,
    Json(payload): Json<McpServerRequest>,
) -> Result<impl IntoResponse> {
    require_authenticated_write(&state, &headers).await?;
    config_files::upsert_mcp_server(&state.paths, &app, &id, payload)?;
    Ok(Json(MessageResponse {
        message: "MCP server saved".to_string(),
    }))
}

pub(crate) async fn delete_mcp_server(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((app, id)): Path<(String, String)>,
) -> Result<impl IntoResponse> {
    require_authenticated_write(&state, &headers).await?;
    config_files::delete_mcp_server(&state.paths, &app, &id)?;
    Ok(Json(MessageResponse {
        message: "MCP server deleted".to_string(),
    }))
}

pub(crate) async fn services(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse> {
    state.require_auth(&headers).await?;
    Ok(Json(read_service_statuses().await?))
}

pub(crate) async fn restart_service(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(name): Path<String>,
) -> Result<impl IntoResponse> {
    require_authenticated_write(&state, &headers).await?;
    ensure_managed_program(&name)?;
    let output = Command::new("supervisorctl")
        .args(["-c", "/etc/supervisor/supervisord.conf", "restart", &name])
        .output()
        .await
        .map_err(|error| ServiceError::Command(format!("failed to execute supervisorctl: {error}")))?;

    if !output.status.success() {
        return Err(ServiceError::Command(format!(
            "supervisorctl restart failed: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }

    Ok(Json(MessageResponse {
        message: String::from_utf8_lossy(&output.stdout).trim().to_string(),
    }))
}

async fn require_authenticated_write(state: &AppState, headers: &HeaderMap) -> Result<()> {
    require_same_origin(headers)?;
    state.require_auth(headers).await
}

async fn read_service_statuses() -> Result<Vec<ManagedServiceStatus>> {
    let output = Command::new("supervisorctl")
        .args(["-c", "/etc/supervisor/supervisord.conf", "status"])
        .output()
        .await
        .map_err(|error| ServiceError::Command(format!("failed to execute supervisorctl: {error}")))?;

    if !output.status.success() {
        return Err(ServiceError::Command(format!(
            "supervisorctl status failed: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout
        .lines()
        .filter_map(parse_service_status_line)
        .filter(|service| MANAGED_PROGRAMS.contains(&service.name.as_str()))
        .collect())
}

fn ensure_managed_program(name: &str) -> Result<()> {
    if MANAGED_PROGRAMS.contains(&name) {
        Ok(())
    } else {
        Err(ServiceError::BadRequest("unsupported service".to_string()))
    }
}

fn parse_service_status_line(line: &str) -> Option<ManagedServiceStatus> {
    let mut fields = line.split_whitespace();
    let name = fields.next()?.to_string();
    let state = fields.next()?.to_string();
    let detail = fields.collect::<Vec<_>>().join(" ");
    Some(ManagedServiceStatus { name, state, detail })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_supervisor_status_line() {
        let parsed = parse_service_status_line("opencode RUNNING pid 12, uptime 0:00:03")
            .expect("parse status");

        assert_eq!(parsed.name, "opencode");
        assert_eq!(parsed.state, "RUNNING");
        assert_eq!(parsed.detail, "pid 12, uptime 0:00:03");
    }

    #[test]
    fn rejects_unknown_supervisor_program() {
        assert!(matches!(
            ensure_managed_program("dockerd"),
            Err(ServiceError::BadRequest(_))
        ));
    }
}
