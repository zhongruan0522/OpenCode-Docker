use std::{collections::BTreeMap, fs, io::Write, path::Path};

use serde_json::{json, Map, Value};
use toml_edit::{value as toml_value, Array, DocumentMut, Item, Table};

use crate::{
    auth::ConfigPaths,
    error::{Result, ServiceError},
    models::{
        ActiveCodexProviderRequest, ActiveModelRequest, CodexConfigResponse,
        CodexProviderRequest, ConfigResponse, McpServerRequest, McpTransport,
        OpenCodeConfigResponse, OpenCodeProviderRequest,
    },
    url_utils,
};

const REDACTED: &str = "********";
const BUILTIN_CODEX_PROVIDER_IDS: &[&str] = &["openai", "ollama", "lmstudio", "amazon-bedrock"];

pub(crate) fn load_config(paths: &ConfigPaths) -> Result<ConfigResponse> {
    let opencode = read_opencode_config(&paths.opencode_config)?;
    let codex_doc = read_codex_config(&paths.codex_config)?;
    let codex_json = codex_doc_to_json(&codex_doc)?;

    Ok(ConfigResponse {
        opencode: OpenCodeConfigResponse {
            path: paths.opencode_config.display().to_string(),
            model: opencode
                .get("model")
                .and_then(|value| value.as_str())
                .map(str::to_string),
            providers: object_section(&opencode, "provider"),
            mcp: object_section(&opencode, "mcp"),
        },
        codex: CodexConfigResponse {
            path: paths.codex_config.display().to_string(),
            auth_mode: read_codex_auth_mode(&paths.codex_auth)?,
            model: codex_json
                .get("model")
                .and_then(|value| value.as_str())
                .map(str::to_string),
            model_provider: codex_json
                .get("model_provider")
                .and_then(|value| value.as_str())
                .map(str::to_string),
            providers: object_section(&codex_json, "model_providers"),
            mcp: object_section(&codex_json, "mcp_servers"),
        },
    })
}

pub(crate) fn upsert_opencode_provider(
    paths: &ConfigPaths,
    id: &str,
    payload: OpenCodeProviderRequest,
) -> Result<()> {
    validate_id(id)?;
    validate_url(&payload.base_url)?;
    if payload.name.trim().is_empty() {
        return Err(ServiceError::BadRequest("provider name is required".to_string()));
    }

    let mut config = read_opencode_config(&paths.opencode_config)?;
    ensure_object_field(&mut config, "provider")?;

    let existing = config
        .get("provider")
        .and_then(|value| value.as_object())
        .and_then(|providers| providers.get(id))
        .cloned();

    let provider = build_opencode_provider(existing, payload);
    config["provider"][id] = provider;
    write_opencode_config(&paths.opencode_config, &config)
}

pub(crate) fn delete_opencode_provider(paths: &ConfigPaths, id: &str) -> Result<()> {
    validate_id(id)?;
    let mut config = read_opencode_config(&paths.opencode_config)?;
    if let Some(providers) = config.get_mut("provider").and_then(|value| value.as_object_mut()) {
        providers.remove(id);
    }
    clear_opencode_model_reference(&mut config, "model", id);
    clear_opencode_model_reference(&mut config, "small_model", id);
    write_opencode_config(&paths.opencode_config, &config)
}

pub(crate) fn set_opencode_active_model(
    paths: &ConfigPaths,
    payload: ActiveModelRequest,
) -> Result<()> {
    if payload.model.trim().is_empty() {
        return Err(ServiceError::BadRequest("model is required".to_string()));
    }

    let mut config = read_opencode_config(&paths.opencode_config)?;
    config["model"] = Value::String(payload.model.trim().to_string());
    write_opencode_config(&paths.opencode_config, &config)
}

pub(crate) fn upsert_codex_provider(
    paths: &ConfigPaths,
    id: &str,
    payload: CodexProviderRequest,
) -> Result<()> {
    validate_id(id)?;
    if BUILTIN_CODEX_PROVIDER_IDS.contains(&id) {
        return Err(ServiceError::BadRequest(
            "built-in Codex providers cannot be overwritten here".to_string(),
        ));
    }
    validate_url(&payload.base_url)?;
    if payload.name.trim().is_empty() {
        return Err(ServiceError::BadRequest("provider name is required".to_string()));
    }

    let mut doc = read_codex_config(&paths.codex_config)?;
    ensure_toml_table(&mut doc, "model_providers");
    let existing = doc
        .get("model_providers")
        .and_then(|item| item.as_table())
        .and_then(|table| table.get(id))
        .and_then(|item| item.as_table())
        .cloned();

    doc["model_providers"][id] = Item::Table(build_codex_provider(payload, existing)?);
    write_codex_config(&paths.codex_config, &doc)
}

pub(crate) fn delete_codex_provider(paths: &ConfigPaths, id: &str) -> Result<()> {
    validate_id(id)?;
    let mut doc = read_codex_config(&paths.codex_config)?;
    let removed_active_provider = doc.get("model_provider").and_then(|item| item.as_str()) == Some(id);
    if let Some(model_providers) = doc
        .get_mut("model_providers")
        .and_then(|item| item.as_table_like_mut())
    {
        model_providers.remove(id);
    }
    if removed_active_provider {
        doc.as_table_mut().remove("model_provider");
    }
    write_codex_config(&paths.codex_config, &doc)
}

pub(crate) fn set_codex_active_provider(
    paths: &ConfigPaths,
    payload: ActiveCodexProviderRequest,
) -> Result<()> {
    validate_id(&payload.model_provider)?;
    let mut doc = read_codex_config(&paths.codex_config)?;
    if !codex_provider_exists(&doc, payload.model_provider.trim()) {
        return Err(ServiceError::BadRequest(
            "Codex provider does not exist".to_string(),
        ));
    }
    doc["model_provider"] = toml_value(payload.model_provider.trim());
    if let Some(model) = payload.model.as_deref() {
        let model = model.trim();
        if model.is_empty() {
            doc.as_table_mut().remove("model");
        } else {
            doc["model"] = toml_value(model);
        }
    }
    write_codex_config(&paths.codex_config, &doc)
}

pub(crate) fn upsert_mcp_server(
    paths: &ConfigPaths,
    app: &str,
    id: &str,
    payload: McpServerRequest,
) -> Result<()> {
    validate_id(id)?;
    validate_mcp_payload(&payload)?;

    match app {
        "opencode" => upsert_opencode_mcp(paths, id, payload),
        "codex" => {
            if payload.transport == McpTransport::Sse {
                return Err(ServiceError::BadRequest(
                    "Codex MCP only supports stdio or streamable HTTP".to_string(),
                ));
            }
            upsert_codex_mcp(paths, id, payload)
        }
        _ => Err(ServiceError::BadRequest("unsupported app".to_string())),
    }
}

pub(crate) fn delete_mcp_server(paths: &ConfigPaths, app: &str, id: &str) -> Result<()> {
    validate_id(id)?;
    match app {
        "opencode" => {
            let mut config = read_opencode_config(&paths.opencode_config)?;
            if let Some(mcp) = config.get_mut("mcp").and_then(|value| value.as_object_mut()) {
                mcp.remove(id);
            }
            write_opencode_config(&paths.opencode_config, &config)
        }
        "codex" => {
            let mut doc = read_codex_config(&paths.codex_config)?;
            if let Some(mcp_servers) = doc
                .get_mut("mcp_servers")
                .and_then(|item| item.as_table_like_mut())
            {
                mcp_servers.remove(id);
            }
            write_codex_config(&paths.codex_config, &doc)
        }
        _ => Err(ServiceError::BadRequest("unsupported app".to_string())),
    }
}

fn read_opencode_config(path: &Path) -> Result<Value> {
    if !path.exists() {
        return Ok(json!({ "$schema": "https://opencode.ai/config.json" }));
    }

    let content = fs::read_to_string(path).map_err(|source| ServiceError::io(path, source))?;
    let value: Value = json5::from_str(&content)
        .map_err(|error| ServiceError::Config(format!("invalid OpenCode config: {error}")))?;
    if !value.is_object() {
        return Err(ServiceError::Config(
            "OpenCode config root must be an object".to_string(),
        ));
    }

    Ok(value)
}

fn write_opencode_config(path: &Path, config: &Value) -> Result<()> {
    if !config.is_object() {
        return Err(ServiceError::Config(
            "OpenCode config root must be an object".to_string(),
        ));
    }
    let text = serde_json::to_string_pretty(config)?;
    write_text_preserving_mount(path, &format!("{text}\n"))
}

fn read_codex_config(path: &Path) -> Result<DocumentMut> {
    if !path.exists() {
        return Ok(DocumentMut::new());
    }

    let content = fs::read_to_string(path).map_err(|source| ServiceError::io(path, source))?;
    content
        .parse::<DocumentMut>()
        .map_err(|error| ServiceError::Toml(format!("invalid Codex config.toml: {error}")))
}

fn write_codex_config(path: &Path, doc: &DocumentMut) -> Result<()> {
    let text = doc.to_string();
    if !text.trim().is_empty() {
        toml::from_str::<toml::Table>(&text)
            .map_err(|error| ServiceError::Toml(format!("invalid generated TOML: {error}")))?;
    }
    write_text_preserving_mount(path, &text)
}

fn write_text_preserving_mount(path: &Path, text: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| ServiceError::io(parent, source))?;
    }

    // The image bind-mounts some live config files directly, so writes must update
    // the mounted inode instead of replacing it with a rename.
    let mut file = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)
        .map_err(|source| ServiceError::io(path, source))?;
    file.write_all(text.as_bytes())
        .map_err(|source| ServiceError::io(path, source))?;
    file.sync_all()
        .map_err(|source| ServiceError::io(path, source))
}

fn read_codex_auth_mode(path: &Path) -> Result<Option<String>> {
    if !path.exists() {
        return Ok(None);
    }

    let content = fs::read_to_string(path).map_err(|source| ServiceError::io(path, source))?;
    let value: Value = serde_json::from_str(&content)?;
    Ok(value
        .get("auth_mode")
        .and_then(|value| value.as_str())
        .map(str::to_string))
}

fn build_opencode_provider(
    existing_provider: Option<Value>,
    payload: OpenCodeProviderRequest,
) -> Value {
    let mut provider = Map::new();
    let mut options = Map::new();
    let mut existing_models = None;

    if let Some(existing) = existing_provider {
        if let Some(existing_object) = existing.as_object() {
            provider = existing_object.clone();
            options = provider
                .get("options")
                .and_then(|value| value.as_object())
                .cloned()
                .unwrap_or_default();
            existing_models = provider
                .get("models")
                .and_then(|value| value.as_object())
                .cloned();
        }
    }

    options.insert("baseURL".to_string(), Value::String(payload.base_url.trim().to_string()));
    let existing_api_key = options
        .get("apiKey")
        .and_then(|value| value.as_str())
        .map(str::to_string);
    if let Some(api_key) = unredacted_or_existing(payload.api_key, existing_api_key) {
        options.insert("apiKey".to_string(), Value::String(api_key));
    } else {
        options.remove("apiKey");
    }
    if !payload.headers.is_empty() {
        options.insert("headers".to_string(), string_map_json(payload.headers));
    } else {
        options.remove("headers");
    }

    provider.insert("npm".to_string(), Value::String(payload.npm.trim().to_string()));
    provider.insert("name".to_string(), Value::String(payload.name.trim().to_string()));
    provider.insert("options".to_string(), Value::Object(options));
    provider.insert(
        "models".to_string(),
        build_opencode_models(existing_models, payload.models),
    );
    Value::Object(provider)
}

fn build_codex_provider(
    payload: CodexProviderRequest,
    existing: Option<Table>,
) -> Result<Table> {
    let mut table = existing.unwrap_or_else(Table::new);
    table["name"] = toml_value(payload.name.trim());
    table["base_url"] = toml_value(payload.base_url.trim());
    if let Some(wire_api) = payload
        .wire_api
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        table["wire_api"] = toml_value(wire_api);
    }
    if payload.requires_openai_auth {
        table["requires_openai_auth"] = toml_value(true);
    } else {
        table.remove("requires_openai_auth");
    }
    if let Some(env_key) = payload.env_key.as_deref().map(str::trim).filter(|value| !value.is_empty()) {
        validate_env_name(env_key)?;
        table["env_key"] = toml_value(env_key);
    } else {
        table.remove("env_key");
    }
    let existing_token = table
        .get("experimental_bearer_token")
        .and_then(|item| item.as_str())
        .map(str::to_string);
    if let Some(token) = unredacted_or_existing(payload.api_key, existing_token) {
        table["experimental_bearer_token"] = toml_value(token);
    } else {
        table.remove("experimental_bearer_token");
    }
    if !payload.http_headers.is_empty() {
        table["http_headers"] = Item::Table(string_table(payload.http_headers));
    } else {
        table.remove("http_headers");
    }
    if !payload.env_http_headers.is_empty() {
        for value in payload.env_http_headers.values() {
            validate_env_name(value)?;
        }
        table["env_http_headers"] = Item::Table(string_table(payload.env_http_headers));
    }

    Ok(table)
}

fn upsert_opencode_mcp(paths: &ConfigPaths, id: &str, payload: McpServerRequest) -> Result<()> {
    let mut config = read_opencode_config(&paths.opencode_config)?;
    ensure_object_field(&mut config, "mcp")?;
    let existing = config
        .get("mcp")
        .and_then(|value| value.as_object())
        .and_then(|mcp| mcp.get(id))
        .and_then(|value| value.as_object())
        .cloned();
    config["mcp"][id] = build_opencode_mcp(existing, payload);
    write_opencode_config(&paths.opencode_config, &config)
}

fn upsert_codex_mcp(paths: &ConfigPaths, id: &str, payload: McpServerRequest) -> Result<()> {
    let mut doc = read_codex_config(&paths.codex_config)?;
    ensure_toml_table(&mut doc, "mcp_servers");
    let existing = doc
        .get("mcp_servers")
        .and_then(|item| item.as_table())
        .and_then(|table| table.get(id))
        .and_then(|item| item.as_table())
        .cloned();
    doc["mcp_servers"][id] = Item::Table(build_codex_mcp(existing, payload)?);
    write_codex_config(&paths.codex_config, &doc)
}

fn build_opencode_mcp(existing: Option<Map<String, Value>>, payload: McpServerRequest) -> Value {
    let mut object = existing
        .filter(|current| matches_transport(current.get("type").and_then(|value| value.as_str()), &payload.transport))
        .unwrap_or_default();
    object.insert("enabled".to_string(), Value::Bool(payload.enabled));
    if let Some(timeout) = payload.timeout_ms {
        object.insert("timeout".to_string(), Value::Number(timeout.into()));
    }

    match payload.transport {
        McpTransport::Stdio => {
            object.insert("type".to_string(), Value::String("local".to_string()));
            let command = std::iter::once(payload.command.expect("validated command"))
                .chain(payload.args)
                .map(Value::String)
                .collect();
            object.insert("command".to_string(), Value::Array(command));
            if !payload.env.is_empty() {
                object.insert("environment".to_string(), string_map_json(payload.env));
            } else {
                object.remove("environment");
            }
        }
        McpTransport::Http | McpTransport::Sse => {
            object.insert("type".to_string(), Value::String("remote".to_string()));
            object.insert(
                "url".to_string(),
                Value::String(payload.url.expect("validated url")),
            );
            if !payload.headers.is_empty() {
                object.insert("headers".to_string(), string_map_json(payload.headers));
                if !object.contains_key("oauth") {
                    object.insert("oauth".to_string(), Value::Bool(false));
                }
            } else {
                object.remove("headers");
            }
        }
    }

    Value::Object(object)
}

fn build_codex_mcp(existing: Option<Table>, payload: McpServerRequest) -> Result<Table> {
    let mut table = existing
        .filter(|current| matches_codex_transport(current, &payload.transport))
        .unwrap_or_else(Table::new);
    table["enabled"] = toml_value(payload.enabled);
    match payload.transport {
        McpTransport::Stdio => {
            table["command"] = toml_value(payload.command.expect("validated command"));
            if !payload.args.is_empty() {
                table["args"] = toml_value(string_array(payload.args));
            } else {
                table.remove("args");
            }
            if !payload.env.is_empty() {
                table["env"] = Item::Table(string_table(payload.env));
            } else {
                table.remove("env");
            }
            if let Some(cwd) = payload.cwd.as_deref().map(str::trim).filter(|value| !value.is_empty()) {
                table["cwd"] = toml_value(cwd);
            }
        }
        McpTransport::Http | McpTransport::Sse => {
            table["url"] = toml_value(payload.url.expect("validated url"));
            if !payload.headers.is_empty() {
                table["http_headers"] = Item::Table(string_table(payload.headers));
            } else {
                table.remove("http_headers");
            }
            if let Some(env_var) = payload
                .bearer_token_env_var
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                validate_env_name(env_var)?;
                table["bearer_token_env_var"] = toml_value(env_var);
            } else {
                table.remove("bearer_token_env_var");
            }
        }
    }
    if let Some(timeout) = payload.startup_timeout_sec {
        table["startup_timeout_sec"] = toml_value(timeout as i64);
    }
    if let Some(timeout) = payload.tool_timeout_sec {
        table["tool_timeout_sec"] = toml_value(timeout as i64);
    }

    Ok(table)
}

fn build_opencode_models(
    existing: Option<Map<String, Value>>,
    models: Vec<crate::models::ModelEntry>,
) -> Value {
    let mut map = existing.unwrap_or_default();
    for model in models {
        let id = model.id.trim();
        if id.is_empty() {
            continue;
        }
        let mut model_obj = map
            .get(id)
            .and_then(|value| value.as_object())
            .cloned()
            .unwrap_or_default();
        model_obj.insert(
            "name".to_string(),
            Value::String(
                model
                    .name
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or(id)
                    .to_string(),
            ),
        );
        let mut limit = model_obj
            .get("limit")
            .and_then(|value| value.as_object())
            .cloned()
            .unwrap_or_default();
        if let Some(context) = model.context {
            limit.insert("context".to_string(), Value::Number(context.into()));
        }
        if let Some(output) = model.output {
            limit.insert("output".to_string(), Value::Number(output.into()));
        }
        if !limit.is_empty() {
            model_obj.insert("limit".to_string(), Value::Object(limit));
        }
        map.insert(id.to_string(), Value::Object(model_obj));
    }

    Value::Object(map)
}

fn codex_provider_exists(doc: &DocumentMut, provider_id: &str) -> bool {
    BUILTIN_CODEX_PROVIDER_IDS.contains(&provider_id)
        || doc
            .get("model_providers")
            .and_then(|item| item.as_table())
            .is_some_and(|providers| providers.contains_key(provider_id))
}

fn clear_opencode_model_reference(config: &mut Value, field: &str, provider_id: &str) {
    let references_provider = config
        .get(field)
        .and_then(|value| value.as_str())
        .is_some_and(|value| value.starts_with(&format!("{provider_id}/")));

    if references_provider {
        if let Some(object) = config.as_object_mut() {
            object.remove(field);
        }
    }
}

fn matches_transport(current: Option<&str>, payload: &McpTransport) -> bool {
    matches!(
        (current, payload),
        (Some("local"), McpTransport::Stdio)
            | (Some("remote"), McpTransport::Http | McpTransport::Sse)
    )
}

fn matches_codex_transport(current: &Table, payload: &McpTransport) -> bool {
    match payload {
        McpTransport::Stdio => current.contains_key("command"),
        McpTransport::Http | McpTransport::Sse => current.contains_key("url"),
    }
}

fn object_section(root: &Value, key: &str) -> BTreeMap<String, Value> {
    root.get(key)
        .and_then(|value| value.as_object())
        .map(|map| {
            map.iter()
                .map(|(key, value)| (key.clone(), sanitize_value(value.clone(), Some(key))))
                .collect()
        })
        .unwrap_or_default()
}

fn codex_doc_to_json(doc: &DocumentMut) -> Result<Value> {
    let text = doc.to_string();
    if text.trim().is_empty() {
        return Ok(Value::Object(Map::new()));
    }
    let value: toml::Value = toml::from_str(&text)
        .map_err(|error| ServiceError::Toml(format!("invalid Codex config.toml: {error}")))?;
    Ok(toml_to_json(value))
}

fn toml_to_json(value: toml::Value) -> Value {
    match value {
        toml::Value::String(value) => Value::String(value),
        toml::Value::Integer(value) => Value::Number(value.into()),
        toml::Value::Float(value) => serde_json::Number::from_f64(value)
            .map(Value::Number)
            .unwrap_or(Value::Null),
        toml::Value::Boolean(value) => Value::Bool(value),
        toml::Value::Datetime(value) => Value::String(value.to_string()),
        toml::Value::Array(values) => Value::Array(values.into_iter().map(toml_to_json).collect()),
        toml::Value::Table(values) => Value::Object(
            values
                .into_iter()
                .map(|(key, value)| (key, toml_to_json(value)))
                .collect(),
        ),
    }
}

fn sanitize_value(value: Value, key_hint: Option<&str>) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(key, value)| {
                    if is_sensitive_key(&key) {
                        (key, Value::String(REDACTED.to_string()))
                    } else {
                        (key.clone(), sanitize_value(value, Some(&key)))
                    }
                })
                .collect(),
        ),
        Value::Array(values) => sanitize_array_values(values, key_hint),
        Value::String(value) => sanitize_string_value(value, key_hint),
        other => other,
    }
}

fn sanitize_array_values(values: Vec<Value>, key_hint: Option<&str>) -> Value {
    if matches!(key_hint, Some("args") | Some("command")) {
        let mut previous_sensitive_flag = false;
        let sanitized = values
            .into_iter()
            .map(|value| {
                if previous_sensitive_flag {
                    previous_sensitive_flag = false;
                    return Value::String(REDACTED.to_string());
                }

                match value {
                    Value::String(value) => {
                        previous_sensitive_flag = is_sensitive_argument_flag(&value);
                        sanitize_string_value(value, key_hint)
                    }
                    other => sanitize_value(other, key_hint),
                }
            })
            .collect();
        return Value::Array(sanitized);
    }

    Value::Array(
        values
            .into_iter()
            .map(|value| sanitize_value(value, key_hint))
            .collect(),
    )
}

fn sanitize_string_value(value: String, key_hint: Option<&str>) -> Value {
    match key_hint.map(|key| key.to_ascii_lowercase()) {
        Some(key) if key == "url" => Value::String(redact_url_query_string(&value)),
        Some(key) if key == "args" || key == "command" => {
            Value::String(redact_argument_string(&value))
        }
        _ => Value::String(value),
    }
}

fn redact_url_query_string(value: &str) -> String {
    let Some((base, query_and_fragment)) = value.split_once('?') else {
        return value.to_string();
    };
    let (query, fragment) = match query_and_fragment.split_once('#') {
        Some((query, fragment)) => (query, Some(fragment)),
        None => (query_and_fragment, None),
    };

    let sanitized_query = query
        .split('&')
        .map(|pair| {
            let Some((name, val)) = pair.split_once('=') else {
                return pair.to_string();
            };
            if is_sensitive_key(name) {
                format!("{name}={REDACTED}")
            } else {
                format!("{name}={val}")
            }
        })
        .collect::<Vec<_>>()
        .join("&");

    match fragment {
        Some(fragment) => format!("{base}?{sanitized_query}#{fragment}"),
        None => format!("{base}?{sanitized_query}"),
    }
}

fn redact_argument_string(value: &str) -> String {
    let Some((name, val)) = value.split_once('=') else {
        return value.to_string();
    };
    let normalized = name.trim_start_matches('-');
    if is_sensitive_key(normalized) {
        format!("{name}={REDACTED}")
    } else {
        format!("{name}={val}")
    }
}

fn is_sensitive_argument_flag(value: &str) -> bool {
    let normalized = value.trim_start_matches('-');
    is_sensitive_key(normalized)
}

fn is_sensitive_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    key.contains("key")
        || key.contains("token")
        || key.contains("secret")
        || key.contains("password")
        || key == "cookie"
        || key == "set-cookie"
        || key == "proxy-authorization"
        || key == "authorization"
        || key == "experimental_bearer_token"
}

fn validate_id(id: &str) -> Result<()> {
    let valid = !id.is_empty()
        && id.len() <= 80
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'));
    if valid {
        Ok(())
    } else {
        Err(ServiceError::BadRequest(
            "id may only contain letters, numbers, dot, dash and underscore".to_string(),
        ))
    }
}

fn validate_url(value: &str) -> Result<()> {
    url_utils::validate_http_url(value)
}

fn validate_env_name(value: &str) -> Result<()> {
    let valid = !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_');
    if valid {
        Ok(())
    } else {
        Err(ServiceError::BadRequest(
            "environment variable names must be uppercase letters, numbers or underscore".to_string(),
        ))
    }
}

fn validate_mcp_payload(payload: &McpServerRequest) -> Result<()> {
    match payload.transport {
        McpTransport::Stdio => {
            if payload
                .command
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .is_none()
            {
                return Err(ServiceError::BadRequest(
                    "stdio MCP server requires command".to_string(),
                ));
            }
        }
        McpTransport::Http | McpTransport::Sse => {
            let url = payload
                .url
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| ServiceError::BadRequest("remote MCP server requires url".to_string()))?;
            validate_url(url)?;
        }
    }

    Ok(())
}

fn ensure_object_field(config: &mut Value, key: &str) -> Result<()> {
    if config.get(key).is_none() {
        config[key] = Value::Object(Map::new());
    }
    if config.get(key).and_then(|value| value.as_object()).is_none() {
        return Err(ServiceError::Config(format!("OpenCode {key} must be an object")));
    }

    Ok(())
}

fn ensure_toml_table(doc: &mut DocumentMut, key: &str) {
    if !doc.contains_key(key) || !doc[key].is_table() {
        doc[key] = toml_edit::table();
    }
}

fn unredacted_or_existing(value: Option<String>, existing: Option<String>) -> Option<String> {
    let Some(value) = value else {
        return existing;
    };
    let value = value.trim();
    if value.is_empty() || value == REDACTED {
        existing
    } else {
        Some(value.to_string())
    }
}

fn string_map_json(values: BTreeMap<String, String>) -> Value {
    Value::Object(
        values
            .into_iter()
            .filter(|(key, value)| !key.trim().is_empty() && !value.trim().is_empty())
            .map(|(key, value)| (key.trim().to_string(), Value::String(value.trim().to_string())))
            .collect(),
    )
}

fn string_table(values: BTreeMap<String, String>) -> Table {
    let mut table = Table::new();
    for (key, value) in values {
        if !key.trim().is_empty() && !value.trim().is_empty() {
            table[key.trim()] = toml_value(value.trim());
        }
    }
    table
}

fn string_array(values: Vec<String>) -> Array {
    let mut array = Array::new();
    for value in values {
        if !value.trim().is_empty() {
            array.push(value.trim());
        }
    }
    array
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn codex_provider_write_preserves_existing_oauth_auth_file() {
        let dir = tempdir().expect("create tempdir");
        let paths = ConfigPaths::from_home(dir.path());
        fs::create_dir_all(paths.codex_auth.parent().unwrap()).expect("create codex dir");
        fs::write(
            &paths.codex_auth,
            r#"{"auth_mode":"chatgpt","tokens":{"access_token":"secret"}}"#,
        )
        .expect("write auth");

        upsert_codex_provider(
            &paths,
            "proxy",
            CodexProviderRequest {
                name: "Proxy".to_string(),
                base_url: "https://proxy.example.com/v1".to_string(),
                env_key: Some("OPENAI_API_KEY".to_string()),
                api_key: None,
                requires_openai_auth: false,
                wire_api: None,
                http_headers: BTreeMap::new(),
                env_http_headers: BTreeMap::new(),
            },
        )
        .expect("write provider");

        let auth_text = fs::read_to_string(&paths.codex_auth).expect("read auth");
        assert!(auth_text.contains("access_token"));
        assert!(!fs::read_to_string(&paths.codex_config)
            .expect("read config")
            .contains("secret"));
    }

    #[test]
    fn rejects_invalid_codex_toml_without_overwriting() {
        let dir = tempdir().expect("create tempdir");
        let paths = ConfigPaths::from_home(dir.path());
        fs::create_dir_all(paths.codex_config.parent().unwrap()).expect("create codex dir");
        fs::write(&paths.codex_config, "[broken").expect("write invalid config");

        let result = upsert_codex_provider(
            &paths,
            "proxy",
            CodexProviderRequest {
                name: "Proxy".to_string(),
                base_url: "https://proxy.example.com/v1".to_string(),
                env_key: Some("OPENAI_API_KEY".to_string()),
                api_key: None,
                requires_openai_auth: false,
                wire_api: None,
                http_headers: BTreeMap::new(),
                env_http_headers: BTreeMap::new(),
            },
        );

        assert!(matches!(result, Err(ServiceError::Toml(_))));
        assert_eq!(
            fs::read_to_string(&paths.codex_config).expect("read config"),
            "[broken"
        );
    }

    #[test]
    fn rejects_overwriting_builtin_codex_provider() {
        let dir = tempdir().expect("create tempdir");
        let paths = ConfigPaths::from_home(dir.path());

        let result = upsert_codex_provider(
            &paths,
            "openai",
            CodexProviderRequest {
                name: "OpenAI Override".to_string(),
                base_url: "https://proxy.example.com/v1".to_string(),
                env_key: Some("OPENAI_API_KEY".to_string()),
                api_key: None,
                requires_openai_auth: false,
                wire_api: None,
                http_headers: BTreeMap::new(),
                env_http_headers: BTreeMap::new(),
            },
        );

        assert!(matches!(result, Err(ServiceError::BadRequest(_))));
    }

    #[test]
    fn opencode_provider_write_preserves_existing_unknown_options() {
        let dir = tempdir().expect("create tempdir");
        let paths = ConfigPaths::from_home(dir.path());
        fs::create_dir_all(paths.opencode_config.parent().unwrap()).expect("create opencode dir");
        fs::write(
            &paths.opencode_config,
            r#"{
              "$schema": "https://opencode.ai/config.json",
              "provider": {
                "proxy": {
                  "npm": "@ai-sdk/openai-compatible",
                  "name": "Proxy",
                  "options": {
                    "baseURL": "https://old.example.com/v1",
                    "timeout": 600000,
                    "setCacheKey": true,
                    "apiKey": "secret"
                  },
                  "models": {
                    "gpt-5.5": {
                      "name": "GPT-5.5",
                      "limit": { "context": 200000 }
                    }
                  }
                }
              }
            }"#,
        )
        .expect("write opencode config");

        upsert_opencode_provider(
            &paths,
            "proxy",
            OpenCodeProviderRequest {
                name: "Proxy Updated".to_string(),
                base_url: "https://new.example.com/v1".to_string(),
                api_key: None,
                npm: "@ai-sdk/openai-compatible".to_string(),
                headers: BTreeMap::new(),
                models: vec![crate::models::ModelEntry {
                    id: "gpt-5.5".to_string(),
                    name: Some("GPT-5.5".to_string()),
                    context: None,
                    output: Some(8192),
                }],
            },
        )
        .expect("update opencode provider");

        let config = read_opencode_config(&paths.opencode_config).expect("read updated config");
        let options = config.pointer("/provider/proxy/options").unwrap();
        assert_eq!(options.get("timeout").and_then(|value| value.as_u64()), Some(600000));
        assert_eq!(options.get("setCacheKey").and_then(|value| value.as_bool()), Some(true));
        assert_eq!(options.get("apiKey").and_then(|value| value.as_str()), Some("secret"));

        let model = config.pointer("/provider/proxy/models/gpt-5.5").unwrap();
        assert_eq!(
            model.pointer("/limit/context").and_then(|value| value.as_u64()),
            Some(200000)
        );
        assert_eq!(
            model.pointer("/limit/output").and_then(|value| value.as_u64()),
            Some(8192)
        );
    }

    #[test]
    fn codex_provider_write_preserves_existing_nested_tables() {
        let dir = tempdir().expect("create tempdir");
        let paths = ConfigPaths::from_home(dir.path());
        fs::create_dir_all(paths.codex_config.parent().unwrap()).expect("create codex dir");
        fs::write(
            &paths.codex_config,
            r#"[model_providers.proxy]
name = "Proxy"
base_url = "https://old.example.com/v1"
env_key = "OPENAI_API_KEY"

[model_providers.proxy.auth]
command = "fetch-token"

[model_providers.proxy.query_params]
api-version = "2025-01-01"
"#,
        )
        .expect("write codex config");

        upsert_codex_provider(
            &paths,
            "proxy",
            CodexProviderRequest {
                name: "Proxy Updated".to_string(),
                base_url: "https://new.example.com/v1".to_string(),
                env_key: Some("OPENAI_API_KEY".to_string()),
                api_key: None,
                requires_openai_auth: false,
                wire_api: None,
                http_headers: BTreeMap::new(),
                env_http_headers: BTreeMap::new(),
            },
        )
        .expect("update codex provider");

        let text = fs::read_to_string(&paths.codex_config).expect("read codex config");
        assert!(text.contains("[model_providers.proxy.auth]"));
        assert!(text.contains("command = \"fetch-token\""));
        assert!(text.contains("[model_providers.proxy.query_params]"));
        assert!(text.contains("api-version = \"2025-01-01\""));
    }

    #[test]
    fn codex_provider_write_preserves_existing_wire_api_when_request_omits_it() {
        let dir = tempdir().expect("create tempdir");
        let paths = ConfigPaths::from_home(dir.path());
        fs::create_dir_all(paths.codex_config.parent().unwrap()).expect("create codex dir");
        fs::write(
            &paths.codex_config,
            r#"[model_providers.proxy]
name = "Proxy"
base_url = "https://old.example.com/v1"
wire_api = "chat"
"#,
        )
        .expect("write codex config");

        upsert_codex_provider(
            &paths,
            "proxy",
            CodexProviderRequest {
                name: "Proxy Updated".to_string(),
                base_url: "https://new.example.com/v1".to_string(),
                env_key: None,
                api_key: None,
                requires_openai_auth: false,
                wire_api: None,
                http_headers: BTreeMap::new(),
                env_http_headers: BTreeMap::new(),
            },
        )
        .expect("update codex provider");

        let text = fs::read_to_string(&paths.codex_config).expect("read codex config");
        assert!(text.contains("wire_api = \"chat\""));
    }

    #[test]
    fn delete_codex_provider_clears_active_provider_reference() {
        let dir = tempdir().expect("create tempdir");
        let paths = ConfigPaths::from_home(dir.path());
        fs::create_dir_all(paths.codex_config.parent().unwrap()).expect("create codex dir");
        fs::write(
            &paths.codex_config,
            r#"model_provider = "proxy"

[model_providers.proxy]
name = "Proxy"
base_url = "https://proxy.example.com/v1"
"#,
        )
        .expect("write codex config");

        delete_codex_provider(&paths, "proxy").expect("delete codex provider");

        let text = fs::read_to_string(&paths.codex_config).expect("read codex config");
        assert!(!text.contains("model_provider = \"proxy\""));
        assert!(!text.contains("[model_providers.proxy]"));
    }

    #[test]
    fn set_codex_active_provider_rejects_unknown_provider() {
        let dir = tempdir().expect("create tempdir");
        let paths = ConfigPaths::from_home(dir.path());
        fs::create_dir_all(paths.codex_config.parent().unwrap()).expect("create codex dir");
        fs::write(&paths.codex_config, "model_provider = \"openai\"\n")
            .expect("write codex config");

        let result = set_codex_active_provider(
            &paths,
            ActiveCodexProviderRequest {
                model_provider: "missing-provider".to_string(),
                model: None,
            },
        );

        assert!(matches!(result, Err(ServiceError::BadRequest(_))));
        let text = fs::read_to_string(&paths.codex_config).expect("read codex config");
        assert!(text.contains("model_provider = \"openai\""));
    }

    #[test]
    fn opencode_remote_mcp_with_headers_writes_oauth_false() {
        let dir = tempdir().expect("create tempdir");
        let paths = ConfigPaths::from_home(dir.path());

        upsert_mcp_server(
            &paths,
            "opencode",
            "remote-docs",
            McpServerRequest {
                transport: McpTransport::Http,
                enabled: true,
                command: None,
                args: Vec::new(),
                url: Some("https://mcp.example.com".to_string()),
                env: BTreeMap::new(),
                headers: BTreeMap::from([(
                    "Authorization".to_string(),
                    "Bearer token".to_string(),
                )]),
                cwd: None,
                timeout_ms: None,
                startup_timeout_sec: None,
                tool_timeout_sec: None,
                bearer_token_env_var: None,
            },
        )
        .expect("write opencode mcp");

        let config = read_opencode_config(&paths.opencode_config).expect("read opencode config");
        let server = config.pointer("/mcp/remote-docs").unwrap();
        assert_eq!(server.get("oauth").and_then(|value| value.as_bool()), Some(false));
    }
}
