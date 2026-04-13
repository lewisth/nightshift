# nightshift

Nightly automated code auditing that runs while you sleep. Nightshift scans your repositories using AI agents, raises GitHub issues for problems found, and ensures nothing is duplicated across runs.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lewisharper/nightshift/main/install.sh | bash
```

This places the `nightshift` script in `~/.local/bin/` and the agent prompts in `~/.local/share/nightshift/prompts/`.

## Prerequisites

- **bash** >= 3.2
- **jq** — JSON parsing ([install](https://jqlang.github.io/jq/download/))
- **gh** — GitHub CLI, installed and authenticated ([install](https://cli.github.com/))
- At least one AI CLI, installed and authenticated:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
  - [Codex CLI](https://github.com/openai/codex) (`codex`)
  - [Cursor CLI](https://www.cursor.com/) (`cursor`)

## Quick start

```bash
nightshift init    # interactive setup wizard
nightshift run     # run a scan immediately
nightshift logs    # view the latest run log
nightshift status  # show config, CLIs, and schedule
```

### `nightshift init`

Walks you through setup:

1. Verifies `gh` is installed and authenticated
2. Detects which AI CLIs are available
3. Lets you assign a CLI to each of the 12 audit agents (or skip any)
4. Asks for your repos root directory (default `~/Developer`)
5. Asks for your preferred nightly run time (default 2 AM)
6. Writes config to `~/.nightshift/config.json`
7. Creates `nightshift` and agent-specific labels in each discovered repo
8. Registers a cron job for the nightly scan

### `nightshift run`

Scans every git repository in your configured root directory. For each repo and each enabled agent:

1. Checks out the default branch and pulls latest
2. Fetches open GitHub issues (for deduplication) and open PRs (for context)
3. Invokes the assigned AI CLI with the agent prompt
4. Parses the JSON response and creates GitHub issues for each finding
5. Skips any issue whose title already exists as an open issue

### `nightshift logs [DATE]`

View the log from the most recent run, or pass a specific date:

```bash
nightshift logs              # latest
nightshift logs 2026-04-13   # specific date
```

### `nightshift status`

Displays your current configuration, detected CLIs and their auth status, number of discovered repos, and the active cron schedule.

## Agents

Nightshift ships with 12 audit agents, each defined as a prompt in the `prompts/` directory:

| Agent | Prompt | GitHub Label | What it finds |
|---|---|---|---|
| Bug detection | `bugs.md` | `bug` | Logical errors, unhandled exceptions, race conditions |
| Security | `security.md` | `security` | Vulnerabilities, hardcoded secrets, injection risks |
| Architecture | `architecture.md` | `architecture` | Layer violations, dependency cycles |
| Anti-patterns | `antipatterns.md` | `anti-pattern` | Deprecated APIs, obsolete patterns |
| Dependencies | `dependencies.md` | `dependencies` | Outdated or abandoned packages |
| Documentation | `documentation.md` | `documentation` | Missing docs on public APIs and config |
| Maintainability | `maintainability.md` | `maintainability` | Duplication, complexity, naming |
| Observability | `observability.md` | `observability` | Missing logging on error paths |
| Performance | `performance.md` | `performance` | Algorithmic complexity issues |
| SOLID principles | `solidprinciples.md` | `solid` | SRP, OCP, LSP, ISP, DIP violations |
| Technical debt | `techdebt.md` | `tech-debt` | TODO/FIXME/HACK comments worth resolving |
| Test coverage | `tests.md` | `testing` | Untested functions, classes, error paths |

## Configuration

### Global config — `~/.nightshift/config.json`

Created by `nightshift init`. Maps each agent to an AI CLI:

```json
{
  "repos_root": "~/Developer",
  "schedule": "0 2 * * *",
  "agents": {
    "bugs": "claude",
    "security": "codex",
    "architecture": "claude"
  }
}
```

### Per-repo override — `<repo>/.nightshift.json`

Override agent assignments or exclude agents for a specific repo:

```json
{
  "agents": {
    "security": "claude"
  },
  "exclude": ["documentation", "solidprinciples"]
}
```

## GitHub issue format

Every issue nightshift creates follows this format:

- **Title:** `[nightshift] <agent-generated title>`
- **Labels:** `nightshift` + agent-specific label
- **Body:** Severity, file location, and a description of the finding

Deduplication is by exact title match against open issues. GitHub is the sole source of truth — no external state file is maintained.

## Logs

Run logs are written to `~/.nightshift/logs/YYYY-MM-DD.log` with timestamped entries per repo and agent, plus a summary line at the end of each run.

## Licence

See [LICENCE.md](LICENCE.md).
