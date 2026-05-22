mod auth;
mod config_files;
mod error;
mod frontend;
mod handlers;
mod models;
mod url_utils;

use axum::{
    routing::{get, post, put},
    Router,
};

pub use auth::AppState;

/// Builds the HTTP router for the OpenCode Docker manager service.
pub fn create_router(state: AppState) -> Router {
    Router::new()
        .route("/", get(frontend::index))
        .route("/app.js", get(frontend::script))
        .route("/styles.css", get(frontend::styles))
        .route("/api/login", post(handlers::login))
        .route("/api/logout", post(handlers::logout))
        .route("/api/session", get(handlers::session))
        .route("/api/config", get(handlers::config))
        .route(
            "/api/opencode/providers/:id",
            put(handlers::upsert_opencode_provider).delete(handlers::delete_opencode_provider),
        )
        .route(
            "/api/opencode/active-model",
            put(handlers::set_opencode_active_model),
        )
        .route(
            "/api/codex/providers/:id",
            put(handlers::upsert_codex_provider).delete(handlers::delete_codex_provider),
        )
        .route(
            "/api/codex/active-provider",
            put(handlers::set_codex_active_provider),
        )
        .route(
            "/api/mcp/:app/:id",
            put(handlers::upsert_mcp_server).delete(handlers::delete_mcp_server),
        )
        .route("/api/services", get(handlers::services))
        .route("/api/services/:name/restart", post(handlers::restart_service))
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use axum::{body::Body, http::{Request, StatusCode}};
    use tempfile::tempdir;
    use tower::ServiceExt;

    use crate::auth::ConfigPaths;

    use super::*;

    #[tokio::test]
    async fn rejects_unauthenticated_config_read() {
        let app = test_app();
        let response = app
            .oneshot(Request::builder().uri("/api/config").body(Body::empty()).unwrap())
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn rejects_unauthenticated_config_write() {
        let app = test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri("/api/opencode/providers/proxy")
                    .header("Host", "localhost:4098")
                    .header("Origin", "http://localhost:4098")
                    .header("Content-Type", "application/json")
                    .body(Body::from(
                        r#"{"name":"Proxy","baseUrl":"https://api.example.com/v1","models":[]}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    fn test_app() -> Router {
        let dir = tempdir().expect("create tempdir");
        let state = AppState::new(
            "admin".to_string(),
            "password".to_string(),
            ConfigPaths::from_home(dir.path()),
        );
        create_router(state)
    }
}
