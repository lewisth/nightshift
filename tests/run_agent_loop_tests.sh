#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

tmpbin="$tmp/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/gh" <<'GHMOCK'
#!/usr/bin/env bash
set -euo pipefail

state_file="${NIGHTSHIFT_LOOP_GH_STATE:?}"
comment_log="${NIGHTSHIFT_LOOP_COMMENT_LOG:?}"
edit_log="${NIGHTSHIFT_LOOP_EDIT_LOG:?}"
pr_create_log="${NIGHTSHIFT_LOOP_PR_CREATE_LOG:?}"
cmd="$*"

if [[ "$cmd" == "repo view"* ]]; then
  if [[ "$cmd" == *"--json defaultBranchRef"* ]]; then
    printf '%s\n' 'main'
  else
    echo "gh stub: unexpected repo view command: $cmd" >&2
    exit 1
  fi
elif [[ "$cmd" == *"issue list"* ]]; then
  count="$(cat "$state_file" 2>/dev/null || echo 0)"
  count=$((count + 1))
  printf '%s' "$count" > "$state_file"

  if [[ "$count" -eq 1 ]]; then
    cat <<'JSON'
[
  {
    "number": 20,
    "title": "PRD: Harden Azure DevOps work item setup and validation",
    "body": "## Problem Statement\n\nParent planning issue.",
    "labels": []
  },
  {
    "number": 21,
    "title": "Explicit ADO identity and safe baseline config",
    "body": "## Parent PRD\n\n#20\n\n## What to build\n\nChild implementation issue.",
    "labels": []
  }
]
JSON
  else
    cat <<'JSON'
[
  {
    "number": 20,
    "title": "PRD: Harden Azure DevOps work item setup and validation",
    "body": "## Problem Statement\n\nParent planning issue.",
    "labels": []
  },
  {
    "number": 21,
    "title": "Explicit ADO identity and safe baseline config",
    "body": "## Parent PRD\n\n#20\n\n## What to build\n\nChild implementation issue.",
    "labels": [
      { "name": "ready-for-pr" }
    ]
  }
]
JSON
  fi
elif [[ "$cmd" == *"issue comment"* ]]; then
  printf '%s\n' "$cmd" >> "$comment_log"
elif [[ "$cmd" == *"issue edit"* ]]; then
  printf '%s\n' "$cmd" >> "$edit_log"
elif [[ "$cmd" == *"pr list"* ]]; then
  printf '%s\n' ''
elif [[ "$cmd" == *"pr create"* ]]; then
  printf '%s\n' "$cmd" >> "$pr_create_log"
  printf '%s\n' 'https://github.com/acme/widget/pull/42'
elif [[ "$cmd" == *"issue close"* ]]; then
  echo "gh stub: issue close should not be called in batch PR mode" >&2
  exit 1
else
  echo "gh stub: unexpected command: $cmd" >&2
  exit 1
fi
GHMOCK
chmod +x "$tmpbin/gh"

cat > "$tmpbin/agent" <<'AGENTMOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '<promise>DONE</promise>'
AGENTMOCK
chmod +x "$tmpbin/agent"

export PATH="$tmpbin:$PATH"
export GITHUB_REPO="acme/widget"
export NIGHTSHIFT_LOOP_GH_STATE="$tmp/gh-state"
export NIGHTSHIFT_LOOP_COMMENT_LOG="$tmp/comment-log"
export NIGHTSHIFT_LOOP_EDIT_LOG="$tmp/edit-log"
export NIGHTSHIFT_LOOP_PR_CREATE_LOG="$tmp/pr-create-log"
export FEATURE_BRANCH="feature/test-batch"

workdir="$tmp/work"
mkdir -p "$workdir"
git -C "$workdir" init --initial-branch=main --quiet

cd "$workdir"
output="$("$ROOT/agent-loop.sh" 2 2>&1)"

if [[ "$output" != *"Issue #21: Explicit ADO identity and safe baseline config"* ]]; then
  echo "FAIL: expected loop to pick issue #21, got output:" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

if ! grep -q "issue edit 21" "$NIGHTSHIFT_LOOP_EDIT_LOG"; then
  echo "FAIL: expected issue #21 to be marked ready for PR" >&2
  exit 1
fi

if ! grep -q -- "--add-label ready-for-pr" "$NIGHTSHIFT_LOOP_EDIT_LOG"; then
  echo "FAIL: expected ready-for-pr label to be added" >&2
  exit 1
fi

if ! grep -q "pr create" "$NIGHTSHIFT_LOOP_PR_CREATE_LOG"; then
  echo "FAIL: expected a batch PR to be created" >&2
  exit 1
fi

if [[ "$output" != *"Created batch PR"* ]]; then
  echo "FAIL: expected output to mention batch PR creation" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo "OK: agent loop batches sub-issues onto a feature branch and opens one PR"
