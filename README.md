# dev-ai

Run AI coding agents (GitHub Copilot, Claude Code, OpenCode) inside an isolated [devcontainer](https://containers.dev/) using **Podman**.

Each project gets its own container built from the project's `.devcontainer/devcontainer.json`. Your AI config (`~/.copilot`, `~/.claude`, `~/.config/opencode`) is bind-mounted in automatically so agents retain their state across sessions.

---

## Requirements

| Tool | Purpose |
|---|---|
| [Podman](https://podman.io/docs/installation) or [Docker](https://docs.docker.com/get-started/get-docker/) | Container runtime (configurable via `~/.dev-ai/config.json`) |
| [@devcontainers/cli](https://github.com/devcontainers/cli) | Lifecycle management (`pnpm add -g @devcontainers/cli`) |
| [pnpm](https://pnpm.io/) | Installs `@devcontainers/cli` on the host and the AI tools in-container (enable via `corepack enable pnpm`) |
| Bash 4.3+ | Script runtime (macOS ships Bash 3 — install via Homebrew) |
| Node.js | Required by `@devcontainers/cli`, `pnpm` (via corepack), and JSON manipulation in `--upgrade` |

---

## Installation

```bash
# 1. Clone the repo
git clone https://github.com/your-org/dev-ai.git ~/dev-ai

# 2. Add bin/ to your PATH (add to ~/.bashrc or ~/.zshrc)
export PATH="$HOME/dev-ai/bin:$PATH"

# 3. Verify
dev-ai --version
```

---

## Quick start

```bash
# Initialise a new project (creates .devcontainer/ from a template)
dev-ai --init /path/to/my-project

# Launch GitHub Copilot inside the devcontainer (default)
dev-ai /path/to/my-project

# Launch from inside the project directory
cd /path/to/my-project && dev-ai
```

On first run the container is built and `postCreate.sh` installs Node.js, pnpm, and the AI tools. Subsequent runs reuse the existing container — startup is instant.

---

## Options

```
Usage: dev-ai [OPTIONS] [WORKSPACE_PATH]

WORKSPACE_PATH  Path to a directory with a .devcontainer/ config.
                Defaults to the current working directory.
```

### Agent selection

| Flag | Agent |
|---|---|
| `-g`, `--github` | GitHub Copilot CLI *(default)* |
| `-o`, `--opencode` | [OpenCode](https://github.com/sst/opencode) |
| `-c`, `--claude` | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) |

### Lifecycle

| Flag | Action |
|---|---|
| `-i`, `--init` | Create a fresh `.devcontainer/` in the workspace from the built-in template |
| `-u`, `--upgrade` | Interactively upgrade `postCreate.sh`, `initialize.sh`, and `devcontainer.json` |
| `-b`, `--build` | Stop and fully rebuild the devcontainer |
| `-f`, `--force-pull` | Pull a fresh base image before rebuilding (use with `--build`) |
| `-m`, `--remount` | Stop and restart with correct mounts (faster than `--build`, skips `postCreate`) |
| `-x`, `--halt` | Stop the running container |
| `-q`, `--quit` | Stop the container automatically when the agent exits |

### Execution

| Flag | Action |
|---|---|
| `-e`, `--execute <bin>` | Run a custom binary instead of an agent (e.g. `/bin/bash`) |
| `-M`, `--model <name>` | Pass a model name to the agent (e.g. `claude-sonnet-4-5`) |

### Ports

| Flag | Action |
|---|---|
| `-p`, `--ports <list>` | Declare forwarded ports in `devcontainer.json` (e.g. `3000,8080` or `8080:80`), then offer to apply them |
| `-P`, `--forward-ports` | Verify port forwarding on the running container and offer to repair it |

Ports are stored as `runArgs` `-p HOST:CONTAINER` entries in `devcontainer.json`, so they are
published every time the container starts. A bare port (`3000`) maps `3000:3000`; use
`HOST:CONTAINER` (`8080:80`) to map different host/container ports. `--init` also asks which
ports to forward. Because ports cannot be published on an already-running container, applying or
repairing them offers to remount (fast) or rebuild the container.

### Info & diagnostics

| Flag | Action |
|---|---|
| `-s`, `--status` | Show container status, image, mounts, and script versions |
| `-t`, `--test` | Run Podman diagnostics (binary, daemon, machine, container run) |
| `-T`, `--trace` | Enable `bash -x` tracing inside `initialize.sh` and `postCreate.sh` |
| `-V`, `--version` | Print version and exit |
| `-h`, `--help` | Print help and exit |

---

## Initialising a project

`dev-ai --init` creates a `.devcontainer/` directory with:

- `devcontainer.json` — image, mounts, hooks (you choose from 17 base images)
- `postCreate.sh` — installs Node.js and AI tools on container build
- `initialize.sh` — runs on host before each container start
- `.gitignore` entries for `.env` and `.tmp`

```bash
dev-ai --init /path/to/my-project
# → prompts you to choose a base image (Ubuntu, Python, Node, Go, …)
# → prompts for tools to install and ports to forward
# → creates .devcontainer/ and adds .env / .tmp to .gitignore

# Forward ports later (and apply to a running container):
dev-ai --ports 3000,8080 /path/to/my-project

# Upgrade scripts in an existing project later:
dev-ai --upgrade /path/to/my-project
```

---

## Configuration

`dev-ai` reads `~/.dev-ai/config.json` for user-level defaults:

```json
{
  "default_agent": "copilot",
  "container_engine": "podman"
}
```

| Key | Values | Default |
|---|---|---|
| `default_agent` | `copilot` \| `opencode` \| `claude` | `copilot` |
| `container_engine` | `podman` \| `docker` | `podman` |

---

## API keys / secrets

Put secrets in `.devcontainer/.env` — it is automatically passed to the container via `--env-file` and excluded from git.

```bash
# .devcontainer/.env
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GITHUB_TOKEN=ghp_...
```

---

## Examples

```bash
# Launch Copilot in the current directory
dev-ai

# Launch Claude Code in a specific project
dev-ai -c ~/projects/my-app

# Launch OpenCode with a specific model
dev-ai -o -M claude-sonnet-4-5 ~/projects/my-app

# Drop into a shell inside the container (for debugging)
dev-ai -e /bin/bash ~/projects/my-app

# Check what's running and which image/mounts are in use
dev-ai -s ~/projects/my-app

# Full rebuild (e.g. after updating the base image)
dev-ai --build ~/projects/my-app

# Run diagnostics if Podman isn't behaving
dev-ai --test
```

---

## Session history

`bin/copilot-session` inspects your local GitHub Copilot CLI history
(`~/.copilot/session-state/`). It needs no container runtime.

```bash
# List recent sessions (default)
copilot-session
copilot-session list --model claude --since 2026-05-01

# Aggregate stats and search
copilot-session stats --project dev-ai
copilot-session messages --search "add unit tests" --limit 10

# Full conversation for one session (ID prefix supported)
copilot-session show abc123

# Deep per-section analysis of one session
copilot-session analyze abc123
```

### `analyze` — deconstruct one session

`analyze ID` breaks a single session down section by section so you can see
where tokens and time went. It prints:

| Section | What it shows |
|---|---|
| Overview | model(s), wall/API time, premium requests, AI credits (AIU), prompt/tool/turn counts, code changes |
| Token breakdown | exact input / output / reasoning / cache tokens, plus the system-prompt, tool-definition, conversation, and total context-window split (from `session.shutdown`) |
| Per-model metrics | requests, token usage, and AI credits (AIU) per model (when more than one was used) |
| Prompt-by-prompt | every user prompt with its turns, tool calls, output tokens, and duration |
| Tool usage | per-tool call counts, success/fail, result size, and total/avg duration |
| Subagents | each subagent's model, tool calls, tokens, and duration |
| Section-by-section timeline | every prompt / reply / tool / subagent / compaction in order, with tokens and duration |
| Summary | subtotals & totals: activity counts, total billed tokens, tool/API/wall time, AI credits (AIU, per-model and per-premium-request), and code changes |

```bash
copilot-session analyze abc123            # full report
copilot-session analyze abc123 --limit 40 # cap the timeline to 40 rows
copilot-session analyze abc123 --json     # machine-readable output
```

Token counts marked `~` are estimated from character length (`≈4 chars/token`);
the exact figures in *Token breakdown*, along with premium requests and AI
credits (AIU), come from the session's shutdown record and are only available
once a session has ended.

---

## Updating dev-ai itself

```bash
cd ~/dev-ai && git pull
# Then upgrade devcontainer scripts in each project:
dev-ai --upgrade /path/to/my-project
```

---

## License

[MIT](LICENSE)
