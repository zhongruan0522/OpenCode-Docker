use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Login payload using the same account variables as OpenCode server auth.
#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

/// Session state exposed to the browser without leaking credentials.
#[derive(Debug, Serialize)]
pub struct SessionResponse {
    pub authenticated: bool,
}

/// Full sanitized configuration snapshot consumed by the manager frontend.
#[derive(Debug, Serialize)]
pub struct ConfigResponse {
    pub opencode: OpenCodeConfigResponse,
    pub codex: CodexConfigResponse,
}

/// Sanitized OpenCode configuration sections managed by this service.
#[derive(Debug, Serialize)]
pub struct OpenCodeConfigResponse {
    pub path: String,
    pub model: Option<String>,
    pub providers: BTreeMap<String, Value>,
    pub mcp: BTreeMap<String, Value>,
}

/// Sanitized Codex configuration sections managed by this service.
#[derive(Debug, Serialize)]
pub struct CodexConfigResponse {
    pub path: String,
    pub auth_mode: Option<String>,
    pub model: Option<String>,
    pub model_provider: Option<String>,
    pub providers: BTreeMap<String, Value>,
    pub mcp: BTreeMap<String, Value>,
}

/// OpenCode provider payload matching the documented `provider.<id>` shape.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeProviderRequest {
    pub name: String,
    pub base_url: String,
    pub api_key: Option<String>,
    #[serde(default = "default_opencode_npm")]
    pub npm: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    #[serde(default)]
    pub models: Vec<ModelEntry>,
}

/// Codex provider payload matching `[model_providers.<id>]` in `config.toml`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexProviderRequest {
    pub name: String,
    pub base_url: String,
    pub env_key: Option<String>,
    pub api_key: Option<String>,
    #[serde(default)]
    pub requires_openai_auth: bool,
    pub wire_api: Option<String>,
    #[serde(default)]
    pub http_headers: BTreeMap<String, String>,
    #[serde(default)]
    pub env_http_headers: BTreeMap<String, String>,
}

/// Model entry used by the simplified OpenCode provider editor.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelEntry {
    pub id: String,
    pub name: Option<String>,
    pub context: Option<u64>,
    pub output: Option<u64>,
}

/// Updates OpenCode's active model string.
#[derive(Debug, Deserialize)]
pub struct ActiveModelRequest {
    pub model: String,
}

/// Updates Codex's active provider and optional default model.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveCodexProviderRequest {
    pub model_provider: String,
    pub model: Option<String>,
}

/// MCP server payload normalized from the two supported clients' formats.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpServerRequest {
    pub transport: McpTransport,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    pub url: Option<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    pub cwd: Option<String>,
    pub timeout_ms: Option<u64>,
    pub startup_timeout_sec: Option<u64>,
    pub tool_timeout_sec: Option<u64>,
    pub bearer_token_env_var: Option<String>,
}

/// MCP transport families exposed by the manager UI.
#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum McpTransport {
    Stdio,
    Http,
    Sse,
}

/// Supervisor-managed process status returned by `supervisorctl status`.
#[derive(Debug, Serialize)]
pub struct ManagedServiceStatus {
    pub name: String,
    pub state: String,
    pub detail: String,
}

#[derive(Debug, Serialize)]
pub struct MessageResponse {
    pub message: String,
}

fn default_opencode_npm() -> String {
    "@ai-sdk/openai-compatible".to_string()
}

fn default_enabled() -> bool {
    true
}
