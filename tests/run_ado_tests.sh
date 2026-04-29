#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NIGHTSHIFT_SKIP_MAIN=1

tmp_root="$(mktemp -d)"
tmpbin="$tmp_root/bin"
errdir="$tmp_root/err"
mkdir -p "$tmpbin" "$errdir"
trap 'rm -rf "$tmp_root"' EXIT

cat > "$tmpbin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
outf=""
wfmt=""
pos=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -sS) shift ;;
    -o) outf="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    -H)
      if [[ -n "${NIGHTSHIFT_MOCK_CURL_HEADERS_LOG:-}" ]]; then
        printf '%s\n' "$2" >> "$NIGHTSHIFT_MOCK_CURL_HEADERS_LOG"
      fi
      shift 2 ;;
    -u) shift 2 ;;
    -X) shift 2 ;;
    -d|--data-binary)
      if [[ -n "${NIGHTSHIFT_MOCK_CURL_POST_BODY_LOG:-}" ]]; then
        printf '%s' "$2" > "$NIGHTSHIFT_MOCK_CURL_POST_BODY_LOG"
      fi
      shift 2 ;;
    *) pos+=("$1"); shift ;;
  esac
done
url="${pos[$(( ${#pos[@]} - 1 ))]}"
: "${NIGHTSHIFT_MOCK_CURL_LOG:=}"
if [[ -n "$NIGHTSHIFT_MOCK_CURL_LOG" ]]; then
  printf '%s' "$url" > "$NIGHTSHIFT_MOCK_CURL_LOG"
fi
code="${NIGHTSHIFT_MOCK_HTTP_CODE:-200}"
body=""
if [[ -n "${NIGHTSHIFT_MOCK_STATE:-}" ]]; then
  prev="$(cat "$NIGHTSHIFT_MOCK_STATE" 2>/dev/null || echo 0)"
  n=$((prev + 1))
  echo "$n" > "$NIGHTSHIFT_MOCK_STATE"
  case "$n" in
    1)
      body='{"workItems":[{"id":42,"url":"u1"},{"id":43,"url":"u2"}]}'
      ;;
    2)
      body='{"count":2,"value":[{"id":42,"fields":{"System.Title":"Alpha"}},{"id":43,"fields":{"System.Title":"Beta"}}]}'
      ;;
    *)
      if [[ -n "${NIGHTSHIFT_MOCK_BODY+x}" ]]; then
        body="$NIGHTSHIFT_MOCK_BODY"
      elif [[ "$code" =~ ^2 ]]; then
        body='{"value":[]}'
      else
        body="{\"typeKey\":\"Error\",\"message\":\"test error for HTTP $code\"}"
      fi
      ;;
  esac
else
  if [[ -n "${NIGHTSHIFT_MOCK_BODY+x}" ]]; then
    body="$NIGHTSHIFT_MOCK_BODY"
  elif [[ "$code" =~ ^2 ]]; then
    body='{"value":[]}'
  else
    body="{\"typeKey\":\"Error\",\"message\":\"test error for HTTP $code\"}"
  fi
fi
if [[ -n "$outf" ]]; then
  printf '%s' "$body" > "$outf"
fi
printf '%s' "$code"
MOCK
chmod +x "$tmpbin/curl"
export PATH="$tmpbin:$PATH"
export NIGHTSHIFT_CURL=curl

# shellcheck disable=SC1091
source "$ROOT/nightshift"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ADO_TEST_IDENTITY="$(jq -nc '{provider:"azuredevops",ado_org:"contoso",ado_project:"Fabrikam",ado_repo:"FabrikamFiber",ado_work_item_type:"Bug"}')"

# --- require_ado_pat / missing PAT ---

unset NIGHTSHIFT_ADO_PAT
if ado_api_request "https://dev.azure.com/x" "_apis/projects" 2>"$errdir/err1"; then
  fail "missing PAT should fail"
fi
if ! grep -q "NIGHTSHIFT_ADO_PAT is not set" "$errdir/err1"; then
  fail "expected missing PAT error, got: $(cat "$errdir/err1")"
fi

# --- success + URL contains api-version=7.1 ---

export NIGHTSHIFT_ADO_PAT="test-pat"
logf="$(mktemp)"
export NIGHTSHIFT_MOCK_CURL_LOG="$logf"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
unset NIGHTSHIFT_MOCK_BODY
out="$(ado_api_request "https://dev.azure.com/contoso" "_apis/projects?%24top=1")"
if ! echo "$out" | jq -e .value &>/dev/null; then
  fail "expected JSON with .value: $out"
fi
u="$(cat "$logf")"
if [[ "$u" != *"api-version=7.1"* ]]; then
  fail "URL missing api-version=7.1: $u"
fi
if [[ "$u" != *"%24top=1"* ]]; then
  fail "URL missing %24top=1: $u"
fi
if [[ "$u" != *"https://dev.azure.com/contoso/_apis/projects"* ]]; then
  fail "unexpected URL: $u"
fi

# --- HTTP 401: distinguish from missing PAT ---

export NIGHTSHIFT_MOCK_HTTP_CODE=401
export NIGHTSHIFT_MOCK_BODY='{"message":"not authorized"}'
if ado_api_request "https://dev.azure.com/contoso" "_apis/foo" 2>"$errdir/err401"; then
  fail "401 should fail"
fi
if ! grep -q "rejected" "$errdir/err401"; then
  fail "expected rejected PAT copy: $(cat "$errdir/err401")"
fi
if grep -q "is not set" "$errdir/err401"; then
  fail "401 error should not look like missing PAT: $(cat "$errdir/err401")"
fi
unset NIGHTSHIFT_MOCK_BODY

# --- 403 / 404 / 5xx (clear messages) ---

export NIGHTSHIFT_MOCK_HTTP_CODE=403
if ado_api_request "https://dev.azure.com/contoso" "_apis/foo" 2>"$errdir/err403"; then fail "403"; fi
grep -q "403" "$errdir/err403" && grep -q "Access denied" "$errdir/err403" || fail "403 message: $(cat "$errdir/err403")"

export NIGHTSHIFT_MOCK_HTTP_CODE=404
if ado_api_request "https://dev.azure.com/contoso" "_apis/foo" 2>"$errdir/err404"; then fail "404"; fi
grep -q "404" "$errdir/err404" && grep -q "not found" "$errdir/err404" || fail "404 message: $(cat "$errdir/err404")"

export NIGHTSHIFT_MOCK_HTTP_CODE=503
if ado_api_request "https://dev.azure.com/contoso" "_apis/foo" 2>"$errdir/err503"; then fail "503"; fi
grep -q "503" "$errdir/err503" && grep -q "service error" "$errdir/err503" || fail "503 message: $(cat "$errdir/err503")"

# --- check_ado_auth ---

export NIGHTSHIFT_MOCK_HTTP_CODE=200
unset NIGHTSHIFT_MOCK_BODY
if ! out="$(check_ado_auth "contoso")"; then
  fail "check_ado_auth should succeed with mock 200: $out"
fi
if [[ "$out" != *"authentication OK"* ]] || [[ "$out" != *"contoso"* ]]; then
  fail "unexpected check_ado_auth success: $out"
fi

if check_ado_auth 2>"$errdir/errca"; then
  fail "check_ado_auth without org should fail"
fi
grep -q "organization" "$errdir/errca" || fail "expected org error: $(cat "$errdir/errca")"

# --- ado_api_post_request ---

export NIGHTSHIFT_ADO_PAT="test-pat"
logf2="$(mktemp)"
export NIGHTSHIFT_MOCK_CURL_LOG="$logf2"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
unset NIGHTSHIFT_MOCK_STATE
export NIGHTSHIFT_MOCK_BODY='{"queryType":"flat","queryResultType":"workItem"}'
if ! out="$(ado_api_post_request "https://dev.azure.com/contoso" "Fabrikam/_apis/wit/wiql" '{"query":"SELECT [System.Id] FROM WorkItems"}')"; then
  fail "post 200: $out"
fi
if ! echo "$out" | jq -e .queryType &>/dev/null; then
  fail "post JSON: $out"
fi
u2="$(cat "$logf2")"
if [[ "$u2" != *"Fabrikam/_apis/wit/wiql"* ]] || [[ "$u2" != *"api-version=7.1"* ]]; then
  fail "post URL: $u2"
fi
unset NIGHTSHIFT_MOCK_BODY

export NIGHTSHIFT_MOCK_HTTP_CODE=401
export NIGHTSHIFT_MOCK_BODY='{"message":"not authorized"}'
if ado_api_post_request "https://dev.azure.com/contoso" "p/_apis/wit/wiql" '{}' 2>"$errdir/errpost401"; then
  fail "post 401 should fail"
fi
grep -q "rejected" "$errdir/errpost401" || fail "post 401 msg: $(cat "$errdir/errpost401")"
unset NIGHTSHIFT_MOCK_BODY

# --- fetch_ado_work_items ---

mkrepo() {
  local d="$1"
  local url="$2"
  mkdir -p "$d"
  git -C "$d" init --quiet
  git -C "$d" remote add origin "$url"
}

unset NIGHTSHIFT_ADO_PAT
out="$(fetch_ado_work_items "$tmp_root/x" '{}')"
if [[ -n "$out" ]]; then
  fail "missing PAT should yield empty titles"
fi

export NIGHTSHIFT_ADO_PAT="test-pat"
mkrepo "$tmp_root/ghonly" 'https://github.com/a/b.git'
out="$(fetch_ado_work_items "$tmp_root/ghonly" '{}')"
if [[ -n "$out" ]]; then
  fail "github repo without ado metadata should yield empty: $out"
fi

mkrepo "$tmp_root/adowiql" 'https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber'
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_STATE="$tmp_root/seqwiql"
echo 0 > "$NIGHTSHIFT_MOCK_STATE"
unset NIGHTSHIFT_MOCK_BODY
out="$(fetch_ado_work_items "$tmp_root/adowiql" "$ADO_TEST_IDENTITY")"
unset NIGHTSHIFT_MOCK_STATE
if [[ "$out" != $'Alpha\nBeta' ]]; then
  fail "want Alpha/Beta titles, got: $out"
fi

unset NIGHTSHIFT_MOCK_STATE
export NIGHTSHIFT_MOCK_BODY='{"workItems":[]}'
export NIGHTSHIFT_MOCK_HTTP_CODE=200
out="$(fetch_ado_work_items "$tmp_root/adowiql" "$ADO_TEST_IDENTITY")"
unset NIGHTSHIFT_MOCK_BODY
if [[ -n "$out" ]]; then
  fail "empty workItems should yield empty string"
fi

export NIGHTSHIFT_MOCK_HTTP_CODE=503
unset NIGHTSHIFT_MOCK_STATE
out="$(fetch_ado_work_items "$tmp_root/adowiql" "$ADO_TEST_IDENTITY")"
if [[ -n "$out" ]]; then
  fail "API error should yield empty titles"
fi

id_no_wit="$(jq -nc '{provider:"azuredevops",ado_org:"contoso",ado_project:"Fabrikam",ado_repo:"FabrikamFiber"}')"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
unset NIGHTSHIFT_MOCK_STATE NIGHTSHIFT_MOCK_BODY
out="$(fetch_ado_work_items "$tmp_root/adowiql" "$id_no_wit" 2>"$errdir/errfetchnowit" || true)"
if [[ -n "$out" ]]; then
  fail "fetch work items without ado_work_item_type should yield empty, got: $out"
fi
grep -Fq "ado_work_item_type" "$errdir/errfetchnowit" || fail "expected WIT error stderr: $(cat "$errdir/errfetchnowit")"

export NIGHTSHIFT_ADO_STRICT=1
if fetch_ado_work_items "$tmp_root/adowiql" "$id_no_wit" 2>"$errdir/errfetchnowitstrict"; then
  fail "strict: fetch work items without ado_work_item_type should fail"
fi
unset NIGHTSHIFT_ADO_STRICT

# --- fetch_ado_prs ---

unset NIGHTSHIFT_ADO_PAT
out="$(fetch_ado_prs "$tmp_root/x" '{}')"
if [[ "$out" != "None" ]]; then
  fail "missing PAT should yield None for PRs: $out"
fi

export NIGHTSHIFT_ADO_PAT="test-pat"
mkrepo "$tmp_root/adoprs" 'https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber'
out="$(fetch_ado_prs "$tmp_root/adoprs" "$ADO_TEST_IDENTITY")"
if [[ "$out" != "None" ]]; then
  fail "PR fetch with no mock body: expected None, got: $out"
fi

pr_log="$(mktemp)"
export NIGHTSHIFT_MOCK_CURL_LOG="$pr_log"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY='{"value":[{"title":"Fix bug","description":"Details here"},{"title":"WIP","description":null}]}'
out="$(fetch_ado_prs "$tmp_root/adoprs" "$ADO_TEST_IDENTITY")"
want=$'PR: Fix bug\nDetails here\n---\nPR: WIP\n\n---'
if [[ "$out" != "$want" ]]; then
  fail "PR format mismatch, got: $(printf %s "$out" | od -c | head -5) want: $(printf %s "$want" | od -c | head -5)"
fi
pr_url="$(cat "$pr_log")"
if [[ "$pr_url" != *"pullrequests"* ]] || [[ "$pr_url" != *"searchCriteria.status=active"* ]]; then
  fail "unexpected PR API URL: $pr_url"
fi
if [[ "$pr_url" != *"api-version=7.1"* ]]; then
  fail "PR URL missing api-version: $pr_url"
fi
unset NIGHTSHIFT_MOCK_BODY

export NIGHTSHIFT_MOCK_BODY='{"value":[]}'
out="$(fetch_ado_prs "$tmp_root/adoprs" "$ADO_TEST_IDENTITY")"
unset NIGHTSHIFT_MOCK_BODY
if [[ "$out" != "None" ]]; then
  fail "empty value[] should be None, got: $out"
fi

export NIGHTSHIFT_MOCK_HTTP_CODE=503
unset NIGHTSHIFT_MOCK_BODY
out="$(fetch_ado_prs "$tmp_root/adoprs" "$ADO_TEST_IDENTITY")"
if [[ "$out" != "None" ]]; then
  fail "PR API error should yield None, got: $out"
fi

out="$(fetch_ado_prs "$tmp_root/adoprs" "$id_no_wit" 2>"$errdir/errprsnowit" || true)"
if [[ "$out" != "None" ]]; then
  fail "fetch PRs without ado_work_item_type should yield None, got: $out"
fi
grep -Fq "ado_work_item_type" "$errdir/errprsnowit" || fail "expected PR WIT stderr: $(cat "$errdir/errprsnowit")"

export NIGHTSHIFT_ADO_STRICT=1
if fetch_ado_prs "$tmp_root/adoprs" "$id_no_wit" 2>"$errdir/errprsnowitstrict"; then
  fail "strict: fetch PRs without ado_work_item_type should fail"
fi
unset NIGHTSHIFT_ADO_STRICT

# --- create_ado_work_item (fresh HOME so ~/.nightshift/config.json is test-controlled) ---

ado_bash() {
  local home="$1"
  local cmd="$2"
  env HOME="$home" PATH="$tmpbin:$PATH" NIGHTSHIFT_CURL=curl NIGHTSHIFT_SKIP_MAIN=1 \
    NIGHTSHIFT_MOCK_CURL_LOG="${NIGHTSHIFT_MOCK_CURL_LOG:-}" \
    NIGHTSHIFT_MOCK_CURL_HEADERS_LOG="${NIGHTSHIFT_MOCK_CURL_HEADERS_LOG:-}" \
    NIGHTSHIFT_MOCK_CURL_POST_BODY_LOG="${NIGHTSHIFT_MOCK_CURL_POST_BODY_LOG:-}" \
    NIGHTSHIFT_MOCK_HTTP_CODE="${NIGHTSHIFT_MOCK_HTTP_CODE:-200}" \
    NIGHTSHIFT_MOCK_BODY="${NIGHTSHIFT_MOCK_BODY:-}" \
    NIGHTSHIFT_ADO_PAT="${NIGHTSHIFT_ADO_PAT-}" \
    bash -c 'source "$1" && eval "$2"' _ "$ROOT/nightshift" "$cmd"
}

cfg_home="$tmp_root/cfghome"
mkdir -p "$cfg_home/.nightshift"
printf '%s\n' '{"ado_default_work_item_type":"Bug"}' > "$cfg_home/.nightshift/config.json"

jq -nc \
  --argjson id "$ADO_TEST_IDENTITY" \
  '$id * {
    ado_work_item_type: "Product Backlog Item",
    ado_area_path: "Fabrikam\\Area",
    ado_iteration_path: "Fabrikam\\Sprint 1",
    ado_fields: {"Custom.Required": "value1"}
  }' > "$tmp_root/repo12.json"

unset NIGHTSHIFT_ADO_PAT
if ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" \"\$(cat \"$tmp_root/repo12.json\")\" bugs \"[nightshift] T\" \"Body\"" 2>"$errdir/errcwi0"; then
  fail "create without PAT should fail"
fi
if ! grep -q "NIGHTSHIFT_ADO_PAT is not set" "$errdir/errcwi0"; then
  fail "create missing PAT message: $(cat "$errdir/errcwi0")"
fi

export NIGHTSHIFT_ADO_PAT="test-pat"
if ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/ghonly\" \"{}\" bugs \"[nightshift] T\" \"Body\"" 2>"$errdir/errcwi1"; then
  fail "create without ADO metadata should fail"
fi
if ! grep -q "identity incomplete" "$errdir/errcwi1"; then
  fail "expected incomplete ADO identity error: $(cat "$errdir/errcwi1")"
fi

if ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" $(printf '%q' "$id_no_wit") bugs \"[nightshift] NoWit\" \"D\"" 2>"$errdir/errcwi_nowit"; then
  fail "create should require per-repo ado_work_item_type; must not fall back to user ado_default_work_item_type"
fi
if ! grep -q "ado_work_item_type is missing" "$errdir/errcwi_nowit"; then
  fail "expected missing per-repo WIT error, got: $(cat "$errdir/errcwi_nowit")"
fi

hdrlog="$(mktemp)"
bodylog="$(mktemp)"
urlog="$(mktemp)"
export NIGHTSHIFT_MOCK_CURL_HEADERS_LOG="$hdrlog"
export NIGHTSHIFT_MOCK_CURL_POST_BODY_LOG="$bodylog"
export NIGHTSHIFT_MOCK_CURL_LOG="$urlog"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY='{"id":99,"rev":1}'
if ! ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" \"\$(cat \"$tmp_root/repo12.json\")\" bugs \"[nightshift] Hello\" \"\$(printf '%b' 'Line1\\n\\nLine2')\""; then
  fail "create should succeed with mock 200"
fi
if ! grep -q 'application/json-patch+json' "$hdrlog"; then
  fail "expected Content-Type json-patch+json in headers, got: $(cat "$hdrlog")"
fi
uwi="$(cat "$urlog")"
if [[ "$uwi" != *"%24Product%20Backlog%20Item"* ]] && [[ "$uwi" != *'workitems/$Product%20Backlog%20Item'* ]]; then
  fail "expected Product Backlog Item in URL, got: $uwi"
fi
patch_body="$(cat "$bodylog")"
if ! echo "$patch_body" | jq -e . >/dev/null; then
  fail "patch not JSON: $patch_body"
fi
if [[ "$(echo "$patch_body" | jq -r '.[] | select(.path=="/fields/System.Title") | .value')" != "[nightshift] Hello" ]]; then
  fail "patch title: $patch_body"
fi
if [[ "$(echo "$patch_body" | jq -r '.[] | select(.path=="/fields/System.Description") | .value')" != $'Line1\n\nLine2' ]]; then
  fail "patch description markdown"
fi
tags_val="$(echo "$patch_body" | jq -r '.[] | select(.path=="/fields/System.Tags") | .value')"
if [[ "$tags_val" != *"nightshift"* ]] || [[ "$tags_val" != *"bug"* ]] || [[ "$tags_val" != *"nightshift-repo:FabrikamFiber"* ]]; then
  fail "patch tags: $tags_val"
fi
if [[ "$(echo "$patch_body" | jq -r '.[] | select(.path=="/fields/System.AreaPath") | .value')" != 'Fabrikam\Area' ]]; then
  fail "patch area path"
fi
if [[ "$(echo "$patch_body" | jq -r '.[] | select(.path=="/fields/System.IterationPath") | .value')" != 'Fabrikam\Sprint 1' ]]; then
  fail "patch iteration path"
fi
if [[ "$(echo "$patch_body" | jq -r '.[] | select(.path=="/fields/Custom.Required") | .value')" != 'value1' ]]; then
  fail "patch ado_fields"
fi

export NIGHTSHIFT_MOCK_CURL_LOG="$urlog"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY='{"id":100,"rev":1}'
BUG_CFG="$(jq -nc --argjson id "$ADO_TEST_IDENTITY" '$id * {ado_work_item_type:"Bug"}')"
if ! ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" $(printf '%q' "$BUG_CFG") bugs \"[nightshift] X\" \"D\""; then
  fail "create Bug type failed"
fi

TASK_CREATE_CFG="$(jq -nc --argjson id "$ADO_TEST_IDENTITY" '$id * {ado_work_item_type:"  TaSk " }')"
if ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" $(printf '%q' "$TASK_CREATE_CFG") bugs \"[nightshift] TaskType\" \"D\"" 2>"$errdir/errcwiTask"; then
  fail "create_ado_work_item should reject built-in Task (trim + case-fold)"
fi
grep -q "not allowed" "$errdir/errcwiTask" || fail "create Task WIT err: $(cat "$errdir/errcwiTask")"
uwi2="$(cat "$urlog")"
if [[ "$uwi2" != *"%24Bug"* ]] && [[ "$uwi2" != *'$Bug'* ]]; then
  fail "Bug work item URL: $uwi2"
fi

CUSTOM_TASK_CFG="$(jq -nc --argjson id "$ADO_TEST_IDENTITY" '$id * {ado_work_item_type:"My CustomerTask"}')"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY='{"id":101,"rev":1}'
if ! ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" $(printf '%q' "$CUSTOM_TASK_CFG") bugs \"[nightshift] CustomTaskOk\" \"D\""; then
  fail "custom WIT whose name contains 'task' should be allowed"
fi
uwi_ct="$(cat "$urlog")"
if [[ "$uwi_ct" != *"CustomerTask"* ]]; then
  fail "expected custom Task-substring WIT in work item URL: $uwi_ct"
fi

cfg_ws="$(jq -nc --argjson id "$ADO_TEST_IDENTITY" '$id * {ado_work_item_type:"   " }')"
if ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" $(printf '%q' "$cfg_ws") bugs \"[nightshift] Ws\" \"D\"" 2>"$errdir/errcwi_ws"; then
  fail "whitespace-only ado_work_item_type should be missing"
fi
grep -q "ado_work_item_type is missing" "$errdir/errcwi_ws" || fail "expected missing WIT err: $(cat "$errdir/errcwi_ws")"

export NIGHTSHIFT_MOCK_HTTP_CODE=400
export NIGHTSHIFT_MOCK_BODY='{"message":"invalid patch"}'
if ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" $(printf '%q' "$BUG_CFG") bugs \"[nightshift] Z\" \"D\"" 2>"$errdir/errcwi400"; then
  fail "HTTP 400 should fail create"
fi
if ! grep -q "400" "$errdir/errcwi400"; then
  fail "expected HTTP 400 in stderr: $(cat "$errdir/errcwi400")"
fi

# --- provider dispatch (ADO path) ---

export NIGHTSHIFT_ADO_PAT="test-pat"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_STATE="$tmp_root/seqdispatch"
echo 0 > "$NIGHTSHIFT_MOCK_STATE"
unset NIGHTSHIFT_MOCK_BODY
out="$(fetch_open_issues_for_repo "$tmp_root/adowiql" "$ADO_TEST_IDENTITY")"
unset NIGHTSHIFT_MOCK_STATE
if [[ "$out" != $'Alpha\nBeta' ]]; then
  fail "fetch_open_issues_for_repo ADO: want Alpha/Beta, got: $out"
fi

export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY='{"value":[{"title":"D1","description":"X"}]}'
out="$(fetch_open_prs_for_repo "$tmp_root/adoprs" "$ADO_TEST_IDENTITY")"
unset NIGHTSHIFT_MOCK_BODY
want=$'PR: D1\nX\n---'
if [[ "$out" != "$want" ]]; then
  fail "fetch_open_prs_for_repo ADO: got: $out"
fi

export NIGHTSHIFT_MOCK_CURL_LOG="$urlog"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY='{"id":101,"rev":1}'
if ! ado_bash "$cfg_home" "create_work_item_for_repo \"$tmp_root/adowiql\" $(printf '%q' "$BUG_CFG") bugs bugs \"[nightshift] Dispatch\" \"Body\""; then
  fail "create_work_item_for_repo ADO path should succeed"
fi

# --- NIGHTSHIFT_ADO_STRICT (cmd_run treats ADO fetch failure as non-zero) ---

export NIGHTSHIFT_ADO_PAT="test-pat"
export NIGHTSHIFT_ADO_STRICT=1
unset NIGHTSHIFT_ADO_PAT
if out="$(fetch_ado_work_items "$tmp_root/x" '{}')"; then
  fail "strict: missing PAT should fail fetch_ado_work_items"
fi
export NIGHTSHIFT_ADO_PAT="test-pat"
export NIGHTSHIFT_MOCK_HTTP_CODE=503
unset NIGHTSHIFT_MOCK_STATE
if out="$(fetch_ado_work_items "$tmp_root/adowiql" "$ADO_TEST_IDENTITY")"; then
  fail "strict: HTTP 503 should fail fetch_ado_work_items"
fi
unset NIGHTSHIFT_ADO_STRICT

export NIGHTSHIFT_MOCK_HTTP_CODE=503
if ! out="$(fetch_ado_work_items "$tmp_root/adowiql" "$ADO_TEST_IDENTITY")"; then
  fail "non-strict: fetch_ado_work_items should return 0 on 503 with empty titles"
fi
if [[ -n "$out" ]]; then
  fail "non-strict 503 should yield empty titles"
fi

# --- cmd_status Azure DevOps section ---

status_home="$tmp_root/statushome"
repos_base="$tmp_root/status_repos"
mkdir -p "$status_home/.nightshift" "$repos_base"
mkrepo "$repos_base/ado1" 'https://dev.azure.com/contoso/Fabrikam/_git/R1'
jq -n '{provider:"azuredevops",ado_org:"contoso",ado_project:"Fabrikam",ado_repo:"R1"}' > "$repos_base/ado1/.nightshift.json"
mkrepo "$repos_base/gh1" 'https://github.com/a/b.git'
jq -n --arg rr "$repos_base" \
  '{repos_root: $rr, schedule: "0 2 * * *", agents: {}}' > "$status_home/.nightshift/config.json"

export NIGHTSHIFT_MOCK_HTTP_CODE=200
unset NIGHTSHIFT_MOCK_BODY NIGHTSHIFT_MOCK_STATE
export NIGHTSHIFT_ADO_PAT="test-pat"
out="$(ado_bash "$status_home" 'unset NIGHTSHIFT_MOCK_BODY; cmd_status')"
echo "$out" | grep -Fq "Azure DevOps:" || fail "status: missing Azure DevOps header"
echo "$out" | grep -Fq "[ok] PAT (valid)" || fail "status: want valid PAT, got: $out"
echo "$out" | grep -Fq "ADO repos: 1" || fail "status: want 1 ADO repo, got: $out"

out="$(ado_bash "$status_home" 'unset NIGHTSHIFT_ADO_PAT NIGHTSHIFT_MOCK_BODY; cmd_status')"
echo "$out" | grep -Fq "[--] PAT (not set)" || fail "status: PAT not set line missing"
if echo "$out" | grep -Fq "ADO repos:"; then
  fail "status: should not show ADO repos when PAT unset"
fi

export NIGHTSHIFT_ADO_PAT="test-pat"
export NIGHTSHIFT_MOCK_HTTP_CODE=401
export NIGHTSHIFT_MOCK_BODY='{"message":"not authorized"}'
out="$(ado_bash "$status_home" 'cmd_status')"
unset NIGHTSHIFT_MOCK_BODY
echo "$out" | grep -Fq "[--] PAT (invalid)" || fail "status: want invalid PAT, got: $out"

# --- ADO work item type fields (required discovery) ---

mock_fields='{"value":[
  {"alwaysRequired":true,"referenceName":"System.Title","name":"Title"},
  {"alwaysRequired":true,"referenceName":"Custom.Req","name":"Custom Req"},
  {"alwaysRequired":true,"referenceName":"System.State","name":"State"},
  {"alwaysRequired":false,"referenceName":"System.Tags","name":"Tags"}
]}'
out="$(ado_wit_fields_response_to_required_prompt_json "$mock_fields")"
if [[ "$(echo "$out" | jq 'length')" != "1" ]]; then
  fail "expected one required prompt field, got: $out"
fi
if [[ "$(echo "$out" | jq -r '.[0].referenceName')" != "Custom.Req" ]]; then
  fail "expected Custom.Req only: $out"
fi

if [[ "$(ado_uri_encode_wit_type_segment "Product Backlog Item")" != "Product%20Backlog%20Item" ]]; then
  fail "WIT URI segment for PBI"
fi

export NIGHTSHIFT_ADO_PAT="test-pat"
fld_log="$(mktemp)"
export NIGHTSHIFT_MOCK_CURL_LOG="$fld_log"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY="$mock_fields"
out="$(ado_fetch_wit_required_fields_json "contoso" "Fabrikam" "Bug")"
unset NIGHTSHIFT_MOCK_BODY
u_f="$(cat "$fld_log")"
if [[ "$u_f" != *"Fabrikam/_apis/wit/workitemtypes/Bug/fields"* ]] || [[ "$u_f" != *"api-version=7.1"* ]]; then
  fail "WIT fields URL: $u_f"
fi
if [[ "$(echo "$out" | jq 'length')" != "1" ]]; then
  fail "fetch required fields json: $out"
fi

if ado_fetch_wit_required_fields_json "contoso" "Fabrikam" "  TaSk " 2>"$errdir/errwitTask"; then
  fail "ado_fetch_wit_required_fields_json should reject built-in Task (trimmed, case-fold)"
fi
grep -q "not allowed" "$errdir/errwitTask" || fail "Task rejection message: $(cat "$errdir/errwitTask")"

cfg_ok='{"ado_work_item_type":"Bug","ado_fields":{"Custom.Req":"v1"}}'
req_one='[{"referenceName":"Custom.Req","name":"Custom Req"}]'
if ! init_ado_repo_fully_configured "$cfg_ok" "$req_one" "Bug"; then
  fail "init_ado_repo_fully_configured should pass"
fi
if init_ado_repo_fully_configured "$cfg_ok" "$req_one" "Task"; then
  fail "init_ado_repo_fully_configured should fail on type mismatch"
fi
TASK_CFG_PARTIAL="$(jq -nc '{ado_work_item_type:"Task","ado_fields":{"Custom.Req":"x"}}')"
if init_ado_repo_fully_configured "$TASK_CFG_PARTIAL" "$req_one" "Task"; then
  fail "init_ado_repo_fully_configured should reject saved builtin Task type"
fi
if init_ado_repo_fully_configured '{"ado_work_item_type":"Bug","ado_fields":{}}' "$req_one" "Bug"; then
  fail "init_ado_repo_fully_configured should fail when field missing"
fi

# --- init_root_has_ado_repos ---

mkdir -p "$tmp_root/initscan"
mkrepo "$tmp_root/initscan/ghonly" 'https://github.com/a/b.git'
if init_root_has_ado_repos "$tmp_root/initscan"; then
  fail "init_root_has_ado_repos should be false for GitHub-only root"
fi

mkrepo "$tmp_root/initscan/adoproj" 'https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber'
if ! init_root_has_ado_repos "$tmp_root/initscan"; then
  fail "init_root_has_ado_repos should be true when any ADO repo exists"
fi

if init_root_has_ado_repos "$tmp_root/nonexistent_dir_ado_test"; then
  fail "init_root_has_ado_repos should be false for missing directory"
fi

echo "OK: ADO REST tests passed"
