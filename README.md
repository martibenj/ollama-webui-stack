# Open WebUI Usage

A self-hosted stack for chatting with local models via [Ollama](https://ollama.com), with a web interface ([Open WebUI](https://github.com/open-webui/open-webui)) and built-in web search with no dependency on a paid third-party API ([SearXNG](https://github.com/searxng/searxng)).

## Architecture

```
┌─────────────┐        Docker network "app-net"        ┌──────────────┐
│  open-webui │ ─────────────────────────────────────  │   searxng    │
│  (container)│  http://searxng:8080/search?q=<query>  │  (container) │
└──────┬──────┘                                        └──────────────┘
       │
       │ host.docker.internal:11434
       ▼
┌─────────────┐
│   ollama    │  (native process, outside Docker)
│  (systemd)  │
└─────────────┘
```

- **Ollama** runs as a native process (not containerized) and listens on `0.0.0.0:11434`.
- **Open WebUI** runs in Docker and reaches Ollama via `host.docker.internal` (resolved thanks to `--add-host=host.docker.internal:host-gateway`).
- **SearXNG** runs in Docker, on the same custom Docker network (`app-net`) as Open WebUI, so the latter can reach it by container name. SearXNG exposes no port on the host: it's only reachable from Open WebUI.

## Prerequisites

- Docker
- Ollama installed (`/usr/local/bin/ollama`), with a dedicated system user `ollama:ollama`
- systemd

## Installation

### 1. Clone this repo and link the service files

```bash
git clone <repo-url> /opt/ollama-webui-stack
sudo ln -s /opt/ollama-webui-stack/ollama.service /etc/systemd/system/ollama.service
sudo ln -s /opt/ollama-webui-stack/open-webui.service /etc/systemd/system/open-webui.service
sudo ln -s /opt/ollama-webui-stack/searxng.service /etc/systemd/system/searxng.service
```

### 2. SearXNG configuration

```bash
sudo mkdir -p /opt/searxng/config
sudo cp searxng-settings.yml /opt/searxng/config/settings.yml
sudo chown -R root:root /opt/searxng/config
```

`settings.yml` must contain:

```yaml
use_default_settings: true

server:
  secret_key: "<generate one, e.g. openssl rand -hex 32>"
  limiter: false
  image_proxy: true

search:
  safe_search: 0
  autocomplete: ""
  default_lang: ""
  formats:
    - html
    - json
```

### 3. Open WebUI secret

```bash
sudo mkdir -p /etc/open-webui
sudo tee /etc/open-webui/webui.env > /dev/null << 'EOF'
WEBUI_SECRET_KEY=<generate a random key, e.g. openssl rand -hex 32>
EOF
sudo chmod 600 /etc/open-webui/webui.env
sudo chown root:root /etc/open-webui/webui.env
```

### 4. Start everything

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ollama.service
sudo systemctl enable --now open-webui.service
sudo systemctl enable --now searxng.service
sudo systemctl status ollama.service open-webui.service searxng.service
```

Open WebUI is available at `http://localhost:3000`.

## Open WebUI configuration — Web Search

In **Admin Panel > Settings > Web Search**:

| Setting | Value |
|---|---|
| Web Search | enabled |
| Web Search Engine | `searxng` |
| Searxng Query URL | `http://searxng:8080/search?q=<query>` |
| Bypass Web Loader | **disabled** (otherwise only SearXNG's snippet is used, without reading the actual page content) |

In **Admin Panel > Models > \<your model\> > Capabilities**:

- ☑ Web Search
- ☑ Built-in Tools *(mandatory — without this, Open WebUI never attaches the `search_web` tool schema to the request sent to the model)*

In **Admin Panel > Models > \<your model\> > Advanced Params**:

- **Function Calling**: `Native`
- **Context Length (`num_ctx`)**: raise to **8192** minimum (Ollama's default of ~2048 truncates the system prompt + tool schema on models with little reserved context, and the model then hallucinates a fake tool call instead of the real one)

Finally, inside the chat itself: enable the **Web Search** toggle via the `+` button next to the input field (needs to be re-enabled for each new conversation).

## Recommended models for tool calling

`llama3.1:8b` is often unreliable at generating properly formed tool calls. `qwen2.5:7b` (or `14b` if VRAM allows) performs noticeably better in practice.