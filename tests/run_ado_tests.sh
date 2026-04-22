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
out="$(fetch_ado_work_items "$tmp_root/adowiql" '{}')"
unset NIGHTSHIFT_MOCK_STATE
if [[ "$out" != $'Alpha\nBeta' ]]; then
  fail "want Alpha/Beta titles, got: $out"
fi

unset NIGHTSHIFT_MOCK_STATE
export NIGHTSHIFT_MOCK_BODY='{"workItems":[]}'
export NIGHTSHIFT_MOCK_HTTP_CODE=200
out="$(fetch_ado_work_items "$tmp_root/adowiql" '{}')"
unset NIGHTSHIFT_MOCK_BODY
if [[ -n "$out" ]]; then
  fail "empty workItems should yield empty string"
fi

export NIGHTSHIFT_MOCK_HTTP_CODE=503
unset NIGHTSHIFT_MOCK_STATE
out="$(fetch_ado_work_items "$tmp_root/adowiql" '{}')"
if [[ -n "$out" ]]; then
  fail "API error should yield empty titles"
fi

# --- fetch_ado_prs ---

unset NIGHTSHIFT_ADO_PAT
out="$(fetch_ado_prs "$tmp_root/x" '{}')"
if [[ "$out" != "None" ]]; then
  fail "missing PAT should yield None for PRs: $out"
fi

export NIGHTSHIFT_ADO_PAT="test-pat"
mkrepo "$tmp_root/adoprs" 'https://dev.azure.com/contoso/Fabrikam/_git/FabrikamFiber'
out="$(fetch_ado_prs "$tmp_root/adoprs" '{}')"
if [[ "$out" != "None" ]]; then
  fail "PR fetch with no mock body: expected None, got: $out"
fi

pr_log="$(mktemp)"
export NIGHTSHIFT_MOCK_CURL_LOG="$pr_log"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY='{"value":[{"title":"Fix bug","description":"Details here"},{"title":"WIP","description":null}]}'
out="$(fetch_ado_prs "$tmp_root/adoprs" '{}')"
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
out="$(fetch_ado_prs "$tmp_root/adoprs" '{}')"
unset NIGHTSHIFT_MOCK_BODY
if [[ "$out" != "None" ]]; then
  fail "empty value[] should be None, got: $out"
fi

export NIGHTSHIFT_MOCK_HTTP_CODE=503
unset NIGHTSHIFT_MOCK_BODY
out="$(fetch_ado_prs "$tmp_root/adoprs" '{}')"
if [[ "$out" != "None" ]]; then
  fail "PR API error should yield None, got: $out"
fi

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
printf '%s\n' '{"ado_default_work_item_type":"Task"}' > "$cfg_home/.nightshift/config.json"

cat > "$tmp_root/repo12.json" <<'JSON'
{
  "ado_area_path": "Fabrikam\\Area",
  "ado_iteration_path": "Fabrikam\\Sprint 1",
  "ado_fields": {"Custom.Required": "value1"}
}
JSON

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
if ! grep -q "Cannot create Azure DevOps work item" "$errdir/errcwi1"; then
  fail "expected metadata error: $(cat "$errdir/errcwi1")"
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
if [[ "$uwi" != *"workitems/%24Task"* ]] && [[ "$uwi" != *'workitems/$Task'* ]]; then
  fail "expected workitems \$Task in URL (global default), got: $uwi"
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
if ! ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" '{\"ado_work_item_type\":\"Bug\"}' bugs \"[nightshift] X\" \"D\""; then
  fail "create Bug type failed"
fi
uwi2="$(cat "$urlog")"
if [[ "$uwi2" != *"%24Bug"* ]] && [[ "$uwi2" != *'$Bug'* ]]; then
  fail "repo ado_work_item_type should override global Task: $uwi2"
fi

export NIGHTSHIFT_MOCK_HTTP_CODE=400
export NIGHTSHIFT_MOCK_BODY='{"message":"invalid patch"}'
if ado_bash "$cfg_home" "create_ado_work_item \"$tmp_root/adowiql\" \"{}\" bugs \"[nightshift] Z\" \"D\"" 2>"$errdir/errcwi400"; then
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
out="$(fetch_open_issues_for_repo "$tmp_root/adowiql" '{}')"
unset NIGHTSHIFT_MOCK_STATE
if [[ "$out" != $'Alpha\nBeta' ]]; then
  fail "fetch_open_issues_for_repo ADO: want Alpha/Beta, got: $out"
fi

export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY='{"value":[{"title":"D1","description":"X"}]}'
out="$(fetch_open_prs_for_repo "$tmp_root/adoprs" '{}')"
unset NIGHTSHIFT_MOCK_BODY
want=$'PR: D1\nX\n---'
if [[ "$out" != "$want" ]]; then
  fail "fetch_open_prs_for_repo ADO: got: $out"
fi

export NIGHTSHIFT_MOCK_CURL_LOG="$urlog"
export NIGHTSHIFT_MOCK_HTTP_CODE=200
export NIGHTSHIFT_MOCK_BODY='{"id":101,"rev":1}'
if ! ado_bash "$cfg_home" "create_work_item_for_repo \"$tmp_root/adowiql\" '{\"ado_work_item_type\":\"Bug\"}' bugs bugs \"[nightshift] Dispatch\" \"Body\""; then
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
if out="$(fetch_ado_work_items "$tmp_root/adowiql" '{}')"; then
  fail "strict: HTTP 503 should fail fetch_ado_work_items"
fi
unset NIGHTSHIFT_ADO_STRICT

export NIGHTSHIFT_MOCK_HTTP_CODE=503
if ! out="$(fetch_ado_work_items "$tmp_root/adowiql" '{}')"; then
  fail "non-strict: fetch_ado_work_items should return 0 on 503 with empty titles"
fi
if [[ -n "$out" ]]; then
  fail "non-strict 503 should yield empty titles"
fi

echo "OK: ADO REST tests passed"
