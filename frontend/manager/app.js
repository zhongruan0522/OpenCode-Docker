const state = { config: null };

const $ = (selector) => document.querySelector(selector);
const loginPanel = $("#loginPanel");
const appPanel = $("#appPanel");
const logoutButton = $("#logoutButton");
const toast = $("#toast");

async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: options.body ? { "Content-Type": "application/json" } : undefined,
    ...options,
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => ({ error: response.statusText }));
    throw new Error(payload.error || response.statusText);
  }
  return response.json();
}

function showToast(message, type = "ok") {
  toast.textContent = message;
  toast.dataset.type = type;
  toast.classList.remove("hidden");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => toast.classList.add("hidden"), 3200);
}

function setAuthenticated(authenticated) {
  loginPanel.classList.toggle("hidden", authenticated);
  appPanel.classList.toggle("hidden", !authenticated);
  logoutButton.classList.toggle("hidden", !authenticated);
}

async function boot() {
  const session = await api("/api/session");
  setAuthenticated(session.authenticated);
  if (session.authenticated) {
    await Promise.all([loadConfig(), loadServices()]);
  }
}

async function loadConfig() {
  state.config = await api("/api/config");
  renderConfig(state.config);
}

async function loadServices() {
  const services = await api("/api/services");
  const root = $("#services");
  root.innerHTML = services.map((service) => `
    <div class="row">
      <div>
        <strong>${escapeHtml(service.name)}</strong>
        <span class="pill ${service.state === "RUNNING" ? "good" : "bad"}">${escapeHtml(service.state)}</span>
        <p>${escapeHtml(service.detail || "无详情")}</p>
      </div>
      <button data-restart="${escapeHtml(service.name)}" type="button">重启</button>
    </div>
  `).join("") || empty("未读取到服务状态");
}

function renderConfig(config) {
  $("#opencodePath").textContent = `OpenCode: ${config.opencode.path}`;
  $("#codexPath").textContent = `Codex: ${config.codex.path}`;
  $("#codexAuthMode").textContent = `Codex Auth: ${config.codex.auth_mode || "未检测"}`;
  $("#opencodeModel").value = config.opencode.model || "";
  $("#codexProvider").value = config.codex.model_provider || "";
  $("#codexModel").value = config.codex.model || "";
  renderMap("#opencodeProviders", config.opencode.providers, "opencode-provider");
  renderMap("#codexProviders", config.codex.providers, "codex-provider");
  renderMap("#opencodeMcp", config.opencode.mcp, "mcp-opencode");
  renderMap("#codexMcp", config.codex.mcp, "mcp-codex");
}

function renderMap(selector, values, action) {
  const entries = Object.entries(values || {});
  $(selector).innerHTML = entries.map(([id, value]) => `
    <div class="row">
      <div>
        <strong>${escapeHtml(id)}</strong>
        <pre>${escapeHtml(JSON.stringify(value, null, 2))}</pre>
      </div>
      <button class="danger" data-delete-${action}="${escapeHtml(id)}" type="button">删除</button>
    </div>
  `).join("") || empty("暂无配置");
}

function empty(text) {
  return `<p class="empty">${escapeHtml(text)}</p>`;
}

function formValue(form, name) {
  return new FormData(form).get(name)?.toString().trim() || "";
}

function parseJsonObject(input) {
  const value = input.trim();
  if (!value) return {};
  const parsed = JSON.parse(value);
  if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") {
    throw new Error("JSON 必须是对象");
  }
  return parsed;
}

function parseModels(value) {
  return value.split("\n").map((line) => line.trim()).filter(Boolean).map((line) => {
    const [id, name] = line.split("=");
    return { id: id.trim(), name: (name || id).trim() };
  });
}

function parseArgs(value) {
  const trimmed = value.trim();
  if (!trimmed) return [];
  if (trimmed.startsWith("[")) {
    const parsed = JSON.parse(trimmed);
    if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== "string")) {
      throw new Error("Args JSON 必须是字符串数组");
    }
    return parsed.map((item) => item.trim()).filter(Boolean);
  }
  return trimmed.split("\n").map((item) => item.trim()).filter(Boolean);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

$("#loginForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  try {
    const form = event.currentTarget;
    await api("/api/login", {
      method: "POST",
      body: JSON.stringify({ username: formValue(form, "username"), password: formValue(form, "password") }),
    });
    setAuthenticated(true);
    await Promise.all([loadConfig(), loadServices()]);
  } catch (error) {
    showToast(error.message, "bad");
  }
});

logoutButton.addEventListener("click", async () => {
  await api("/api/logout", { method: "POST" });
  setAuthenticated(false);
});

$("#refreshServicesButton").addEventListener("click", () => loadServices().catch((error) => showToast(error.message, "bad")));

$("#saveOpenCodeModelButton").addEventListener("click", async () => {
  await runAction(async () => {
    await api("/api/opencode/active-model", { method: "PUT", body: JSON.stringify({ model: $("#opencodeModel").value.trim() }) });
    await loadConfig();
  });
});

$("#saveCodexActiveButton").addEventListener("click", async () => {
  await runAction(async () => {
    await api("/api/codex/active-provider", {
      method: "PUT",
      body: JSON.stringify({ modelProvider: $("#codexProvider").value.trim(), model: $("#codexModel").value.trim() }),
    });
    await loadConfig();
  });
});

$("#opencodeProviderForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  await runAction(async () => {
    await api(`/api/opencode/providers/${encodeURIComponent(formValue(form, "id"))}`, {
      method: "PUT",
      body: JSON.stringify({
        name: formValue(form, "name"),
        baseUrl: formValue(form, "baseUrl"),
        apiKey: formValue(form, "apiKey"),
        npm: formValue(form, "npm") || "@ai-sdk/openai-compatible",
        models: parseModels(formValue(form, "models")),
        headers: parseJsonObject(formValue(form, "headers")),
      }),
    });
    form.reset();
    form.elements.npm.value = "@ai-sdk/openai-compatible";
    await loadConfig();
  });
});

$("#codexProviderForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  await runAction(async () => {
    await api(`/api/codex/providers/${encodeURIComponent(formValue(form, "id"))}`, {
      method: "PUT",
      body: JSON.stringify({
        name: formValue(form, "name"),
        baseUrl: formValue(form, "baseUrl"),
        envKey: formValue(form, "envKey"),
        apiKey: formValue(form, "apiKey"),
        requiresOpenaiAuth: form.elements.requiresOpenaiAuth.checked,
        httpHeaders: parseJsonObject(formValue(form, "headers")),
      }),
    });
    form.reset();
    await loadConfig();
  });
});

document.querySelectorAll(".mcp-form").forEach((form) => {
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    await runAction(async () => {
      await api(`/api/mcp/${form.dataset.mcpApp}/${encodeURIComponent(formValue(form, "id"))}`, {
        method: "PUT",
        body: JSON.stringify({
          transport: formValue(form, "transport"),
          command: formValue(form, "command"),
          args: parseArgs(formValue(form, "args")),
          cwd: formValue(form, "cwd"),
          url: formValue(form, "url"),
          env: parseJsonObject(formValue(form, "env")),
          headers: parseJsonObject(formValue(form, "headers")),
          bearerTokenEnvVar: formValue(form, "bearerTokenEnvVar"),
          enabled: form.elements.enabled.checked,
        }),
      });
      form.reset();
      form.elements.enabled.checked = true;
      await loadConfig();
    });
  });
});

document.addEventListener("click", async (event) => {
  const target = event.target;
  if (!(target instanceof HTMLElement)) return;
  const restart = target.dataset.restart;
  if (restart) {
    await runAction(async () => {
      const result = await api(`/api/services/${encodeURIComponent(restart)}/restart`, { method: "POST" });
      showToast(result.message || "服务已重启");
      await loadServices();
    });
  }
  await handleDelete(target, "deleteOpencodeProvider", (id) => `/api/opencode/providers/${id}`);
  await handleDelete(target, "deleteCodexProvider", (id) => `/api/codex/providers/${id}`);
  await handleDelete(target, "deleteMcpOpencode", (id) => `/api/mcp/opencode/${id}`);
  await handleDelete(target, "deleteMcpCodex", (id) => `/api/mcp/codex/${id}`);
});

async function handleDelete(target, datasetKey, pathBuilder) {
  const id = target.dataset[datasetKey];
  if (!id) return;
  await runAction(async () => {
    await api(pathBuilder(encodeURIComponent(id)), { method: "DELETE" });
    await loadConfig();
  });
}

async function runAction(action) {
  try {
    await action();
    showToast("已保存");
  } catch (error) {
    showToast(error.message, "bad");
  }
}

boot().catch(() => setAuthenticated(false));
