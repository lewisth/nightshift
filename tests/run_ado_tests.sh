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
    -H) shift 2 ;;
    -u) shift 2 ;;
    *) pos+=("$1"); shift ;;
  esac
done
url="${pos[$(( ${#pos[@]} - 1 ))]}"
: "${NIGHTSHIFT_MOCK_CURL_LOG:=}"
if [[ -n "$NIGHTSHIFT_MOCK_CURL_LOG" ]]; then
  printf '%s' "$url" > "$NIGHTSHIFT_MOCK_CURL_LOG"
fi
code="${NIGHTSHIFT_MOCK_HTTP_CODE:-200}"
if [[ -z "${NIGHTSHIFT_MOCK_BODY+x}" ]]; then
  if [[ "$code" =~ ^2 ]]; then
    body='{"value":[]}'
  else
    body="{\"typeKey\":\"Error\",\"message\":\"test error for HTTP $code\"}"
  fi
else
  body="$NIGHTSHIFT_MOCK_BODY"
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

echo "OK: ADO REST tests passed"
