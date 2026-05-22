use std::net::SocketAddr;

use opencode_manager::{create_router, AppState};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let state = AppState::from_env()?;
    let port = std::env::var("MANAGER_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(4098);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;

    axum::serve(listener, create_router(state)).await?;
    Ok(())
}
