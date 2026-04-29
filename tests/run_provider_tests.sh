#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NIGHTSHIFT_SKIP_MAIN=1
# shellcheck disable=SC1091
source "$ROOT/nightshift"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_json_eq() {
    local key="$1"
    local want="$2"
    local json="$3"
    local got
    got="$(echo "$json" | jq -r ".$key")"
    if [[ "$got" != "$want" ]]; then
        fail "$key: want $want, got $got (json=$json)"
    fi
}

# --- parse_ado_remote ---

m="$(parse_ado_remote 'https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber')"
assert_json_eq org contoso "$m"
assert_json_eq project Fabrikam "$m"
assert_json_eq repo FabrikamFiber "$m"

m="$(parse_ado_remote 'https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber.git')"
assert_json_eq repo FabrikamFiber "$m"

m="$(parse_ado_remote 'https://contoso.visualstudio.com/Fabrikam/_git/FabrikamFiber')"
assert_json_eq org contoso "$m"
assert_json_eq project Fabrikam "$m"
assert_json_eq repo FabrikamFiber "$m"

m="$(parse_ado_remote 'https://contoso.visualstudio.com/DefaultCollection/Fabrikam/_git/FabrikamFiber')"
assert_json_eq org contoso "$m"
assert_json_eq project "DefaultCollection/Fabrikam" "$m"
assert_json_eq repo FabrikamFiber "$m"

m="$(parse_ado_remote 'git@ssh.dev.azure.com:v3/contoso/Fabrikam/FabrikamFiber')"
assert_json_eq org contoso "$m"
assert_json_eq project Fabrikam "$m"
assert_json_eq repo FabrikamFiber "$m"

pat='https://PATTOKEN@dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber'
stripped="$(strip_remote_credentials "$pat")"
[[ "$stripped" == "https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber" ]] || fail "strip PAT url"
m="$(parse_ado_remote "$stripped")"
assert_json_eq org contoso "$m"

if parse_ado_remote 'https://github.com/foo/bar.git' &>/dev/null; then
    fail "github url should not parse as ADO"
fi

# --- detect_provider (git remotes) ---

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkrepo() {
    local d="$1"
    local url="$2"
    mkdir -p "$d"
    git -C "$d" init --quiet
    git -C "$d" remote add origin "$url"
}

mkrepo "$tmp/gh" 'https://github.com/acme/widget.git'
p="$(detect_provider "$tmp/gh" '{}')"
[[ "$p" == "github" ]] || fail "github https: $p"

mkrepo "$tmp/ghssh" 'git@github.com:acme/widget.git'
p="$(detect_provider "$tmp/ghssh" '{}')"
[[ "$p" == "github" ]] || fail "github ssh: $p"

mkrepo "$tmp/ado" 'https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber'
p="$(detect_provider "$tmp/ado" '{}')"
[[ "$p" == "unknown" ]] || fail "ado without pinned provider must be unknown, not inferred: $p"

mkrepo "$tmp/unk" 'https://gitlab.com/group/project.git'
p="$(detect_provider "$tmp/unk" '{}')"
[[ "$p" == "unknown" ]] || fail "gitlab: $p"

p="$(detect_provider "$tmp/gh" '{"provider":"azuredevops"}')"
[[ "$p" == "azuredevops" ]] || fail "override provider to ado: $p"

p="$(detect_provider "$tmp/ado" '{"provider":"github"}')"
[[ "$p" == "github" ]] || fail "override provider to github: $p"

# --- resolved_ado_metadata (saved config only; no git-remote merge) ---

meta="$(resolved_ado_metadata "$tmp/ado" '{"provider":"azuredevops","ado_org":"contoso","ado_project":"Fabrikam","ado_repo":"OverrideRepo"}')"
assert_json_eq repo OverrideRepo "$meta"
assert_json_eq org contoso "$meta"

meta="$(resolved_ado_metadata "$tmp/gh" '{"provider":"azuredevops","ado_org":"x","ado_project":"y","ado_repo":"z"}')"
assert_json_eq org x "$meta"
assert_json_eq project y "$meta"
assert_json_eq repo z "$meta"

if init_normalize_work_item_type_choice " task " 2>"$tmp/errwit"; then
    fail "Task should be rejected"
fi
if ! wit="$(init_normalize_work_item_type_choice "My Task Story")"; then
    fail "custom type containing task substring should be allowed"
fi
[[ "$wit" == "My Task Story" ]] || fail "expected custom wit, got $wit"

if ! ado_wit_name_is_forbidden_builtin_task "  TASK "; then
    fail "builtin Task should be rejected (trim + case)"
fi
if ! ado_wit_name_is_forbidden_builtin_task $' \tTaSk\t '; then
    fail "builtin Task should be rejected (internal ws + case)"
fi
if ado_wit_name_is_forbidden_builtin_task "My CustomerTask"; then
    fail "custom WIT names that contain task as substring must not be blocked"
fi

# --- ado_require_saved_identity_runtime: drift vs git origin ---
mkrepo "$tmp/driftADO" 'https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber'
drift_cfg="$(jq -nc '{provider:"azuredevops",ado_org:"wrongorg",ado_project:"Fabrikam",ado_repo:"FabrikamFiber"}')"
if ado_require_saved_identity_runtime "$tmp/driftADO" "$drift_cfg" "Test" 2>"$tmp/drift.err"; then
    fail "saved identity that disagrees with origin should fail drift check"
fi
grep -Fq "does not match origin remote (drift)" "$tmp/drift.err" || fail "expected drift stderr, got $(cat "$tmp/drift.err")"

p="$(ado_org_for_pat_probe "{}")"
[[ -z "$p" ]] || fail "PAT probe org must be empty without saved ADO identity (no git inference)"
p="$(ado_org_for_pat_probe "$(jq -nc '{provider:"azuredevops",ado_org:"contoso",ado_project:"Fabrikam",ado_repo:"R1"}')")"
[[ "$p" == "contoso" ]] || fail "PAT probe org should come from saved ado_org only, got: $p"

# --- provider dispatch (GitHub path via gh stub) ---

tmpbin="$tmp/bin"
mkdir -p "$tmpbin"
cat > "$tmpbin/gh" <<'GHMOCK'
#!/usr/bin/env bash
set -euo pipefail
c="$*"
if [[ "$c" == *"issue list"* ]]; then
  echo '[{"title":"GH Issue One"}]'
elif [[ "$c" == *"pr list"* ]]; then
  echo '[{"title":"GH PR","body":"PR body here"}]'
elif [[ "$c" == *"issue create"* ]]; then
  echo 'https://github.com/acme/widget/issues/42'
else
  echo "gh stub: unexpected: $c" >&2
  exit 1
fi
GHMOCK
chmod +x "$tmpbin/gh"
PATH="$tmpbin:$PATH"

out="$(fetch_open_issues_for_repo "$tmp/gh" '{}')"
[[ "$out" == "GH Issue One" ]] || fail "fetch_open_issues_for_repo github: $out"

out="$(fetch_open_prs_for_repo "$tmp/gh" '{}')"
want=$'PR: GH PR\nPR body here\n---'
[[ "$out" == "$want" ]] || fail "fetch_open_prs_for_repo github: $out"

if ! create_work_item_for_repo "$tmp/gh" '{}' bugs bugs "[nightshift] T" "B"; then
    fail "create_work_item_for_repo github path should succeed"
fi

mkrepo "$tmp/adoBare" 'https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber'
if fetch_open_issues_for_repo "$tmp/adoBare" '{}' 2>"$tmp/errAdoBare"; then
    fail "ado remote without provider=azuredevops should fail fetch_open_issues_for_repo"
fi
grep -q "nightshift init" "$tmp/errAdoBare" || fail "expected init hint stderr: $(cat "$tmp/errAdoBare")"
if create_work_item_for_repo "$tmp/adoBare" '{}' bugs bugs "[nightshift] T" "B" 2>"$tmp/errCwiBare"; then
    fail "ado remote without config should fail create_work_item_for_repo"
fi
grep -q "nightshift init" "$tmp/errCwiBare" || fail "create_work_item ado bare stderr: $(cat "$tmp/errCwiBare")"

echo "OK: provider detection tests passed"
