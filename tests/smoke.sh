#!/usr/bin/env bash
# Smoke test for the open-webui-starter image, run the way Dockhold runs it:
# user 1001, every capability dropped, no privilege escalation, 2 GB of
# memory and no swap, App storage mounted at /data owned root:1001 with mode
# 2770, a fixed PORT, generated secrets, and no outbound network (so the
# provider and the release check are unreachable, which is itself one of the
# things checked). Every assertion goes through Open WebUI's own API from a
# curl helper on the same isolated network. Nothing upstream is mocked.
#
# Usage: tests/smoke.sh <image>
# Needs: docker, jq, bash 4 or newer. Exits non-zero if any case fails.
# Prints one PASS or FAIL line per case, INFO lines for measurements, and the
# container log after a failure. A full run starts the app about ten times
# and each cold start takes half a minute or more (a first start on fresh
# storage takes two: the admin is verified on loopback before the port
# opens), so expect twenty minutes.
set -euo pipefail

IMAGE=${1:?usage: tests/smoke.sh <image>}
CURL_IMAGE=curlimages/curl:8.16.0
HELPER_IMAGE=alpine:3.24
RUN="owuismoke-$$-$RANDOM"
NET="$RUN-net"
APP="$RUN-app"
CURL="$RUN-curl"
PORT=8080
URL="http://owui:$PORT"
MEM=2g
BASE=$(mktemp -d "${TMPDIR:-/tmp}/owuismoke.XXXXXX")
STORAGE_LINE="This app keeps its data on App storage. Turn on App storage in the Size tab; the app restarts on its own."
DB_LINE="This template keeps Open WebUI's data on App storage and does not use the managed database yet. Turn the managed database off for this app and restart it."
VERIFY_LINE="Verifying the admin account before opening the port"
NO_ADMIN_LINE="The admin account could not be created, or the bound WEBUI_ADMIN_EMAIL and WEBUI_ADMIN_PASSWORD do not match the existing admin. Check them on this app's Variables tab and restart."
STOPPED_LINE="Open WebUI stopped during the first start before the admin account could be verified. The lines above say why."
KEY_MISSING_LINE="The app's session key is missing from App storage. Restore it from your backup if the app ever had one, or bind WEBUI_SECRET_KEY to the previous value."
KEY_DAMAGED_LINE="The app's session key file on App storage is damaged. Bind WEBUI_SECRET_KEY to the previous key or restore the file from your backup; the file is never overwritten."
BOOTSTRAP_LINE="Admin account created successfully"
PDF_TEXT="Dockhold ingestion probe: zebra quantum pineapple lantern."

PASS_COUNT=0
FAIL_COUNT=0
UNKNOWN_COUNT=0
HTTP_CODE=000
HTTP_BODY=""

pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
# A case whose precondition was not met on this machine: neither a pass
# nor a failure, reported with the reason.
unknown() { echo "UNKNOWN  $1"; UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)); }
fail() {
  echo "FAIL  $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "----- container log ($APP) -----"
  docker logs "$APP" 2>&1 | tail -n 40 || true
  echo "-------------------------------"
}
report() { if [ "$2" = true ]; then pass "$1"; else fail "$1"; fi; }
info() { echo "INFO  $1"; }

cleanup() {
  docker rm -f "$APP" "$CURL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  # Data dirs are root-owned after the platform-shaped chown, so a root
  # container removes their contents; the base dir itself is ours.
  docker run --rm -v "$BASE:/b" "$HELPER_IMAGE" sh -c 'rm -rf /b/* /b/.[!.]* 2>/dev/null; true' >/dev/null 2>&1 || true
  rmdir "$BASE" 2>/dev/null || true
}
trap cleanup EXIT

rand_hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

# A fresh host dir shaped like the platform's App storage mount.
new_datadir() {
  local d
  d=$(mktemp -d "$BASE/data.XXXXXX")
  docker run --rm -v "$d:/data" "$HELPER_IMAGE" sh -c 'chown 0:1001 /data && chmod 2770 /data' >/dev/null
  echo "$d"
}

# as_root DIR CMD: runs a shell command as root with DIR mounted at /data,
# for the cases that damage or remove files the app owns.
as_root() { docker run --rm -v "$1:/data" "$HELPER_IMAGE" sh -c "$2"; }

# start_app [docker run args...]: the fixed runtime shape plus whatever the
# case adds (mounts, DATA_DIR, secrets). MEM is the memory limit.
start_app() {
  docker rm -f "$APP" >/dev/null 2>&1 || true
  docker run -d --name "$APP" --network "$NET" --network-alias owui \
    --user 1001:1001 --cap-drop ALL --security-opt no-new-privileges \
    --memory "$MEM" --memory-swap "$MEM" \
    -e "PORT=$PORT" "$@" "$IMAGE" >/dev/null 2>"$BASE/run.err" || { cat "$BASE/run.err"; return 1; }
}

stop_app() { docker stop -t 20 "$APP" >/dev/null 2>&1 || true; docker rm -f "$APP" >/dev/null 2>&1 || true; }

app_running() { [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" = true ]; }
app_logs() { docker logs "$APP" 2>&1 || true; }
app_oom() { docker inspect -f '{{.State.OOMKilled}}' "$APP" 2>/dev/null || echo unknown; }
mem_peak_mib() { local b; b=$(docker exec "$APP" cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo ""); [ -n "$b" ] && echo $((b / 1048576)) || echo "n/a"; }
mem_now_mib() { local b; b=$(docker exec "$APP" cat /sys/fs/cgroup/memory.current 2>/dev/null || echo ""); [ -n "$b" ] && echo $((b / 1048576)) || echo "n/a"; }

# Waits until /health answers or the container exits. Returns 1 on either
# failure so a case cannot pass by accident on a dead container. Prints
# the seconds waited. Cold start of this image is measured in tens of
# seconds; the limit is five minutes.
wait_health() {
  local i t0
  t0=$(date +%s.%N)
  for i in $(seq 1 600); do
    app_running || return 1
    if docker exec "$CURL" curl -sf -m 3 -o /dev/null "$URL/health" 2>/dev/null; then
      WAITED=$(printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)")
      return 0
    fi
    sleep 0.5
  done
  return 1
}
WAITED=""

# Prints the exit code once the container has exited, or "running". The
# limit covers a loopback verify pass that ends in a refusal.
wait_exit() {
  local i
  for i in $(seq 1 1200); do
    if ! app_running; then docker inspect -f '{{.State.ExitCode}}' "$APP"; return 0; fi
    sleep 0.25
  done
  echo running
}

# http METHOD PATH BODY TOKEN [extra curl args...]; sets HTTP_CODE, HTTP_BODY.
http() {
  local method=$1 path=$2 body=$3 token=$4
  shift 4
  local args=(-s -m 30 -X "$method" -w $'\n%{http_code}' -H 'Content-Type: application/json')
  if [ -n "$token" ]; then args+=(-H "Authorization: Bearer $token"); fi
  if [ -n "$body" ]; then args+=(--data-binary "$body"); fi
  local out
  if out=$(docker exec "$CURL" curl "${args[@]}" "$@" "$URL$path" 2>/dev/null); then
    HTTP_CODE=${out##*$'\n'}
    HTTP_BODY=${out%$'\n'*}
  else
    HTTP_CODE=000
    HTTP_BODY=""
  fi
}

# http_upload PATH TOKEN FILE_IN_HELPER: multipart upload; sets HTTP_CODE, HTTP_BODY.
http_upload() {
  local out
  if out=$(docker exec "$CURL" curl -s -m 120 -w $'\n%{http_code}' -H "Authorization: Bearer $2" -F "file=@$3" "$URL$1" 2>/dev/null); then
    HTTP_CODE=${out##*$'\n'}
    HTTP_BODY=${out%$'\n'*}
  else
    HTTP_CODE=000
    HTTP_BODY=""
  fi
}

# login EMAIL PASSWORD: prints a token, or nothing when login is refused.
login() {
  http POST /api/v1/auths/signin "$(jq -cn --arg e "$1" --arg p "$2" '{email:$e,password:$p}')" ""
  if [ "$HTTP_CODE" = 200 ]; then printf '%s' "$HTTP_BODY" | jq -r '.token // empty'; fi
}

users_json() { # TOKEN -> compact {total, roles}
  http GET "/api/v1/users/" "" "$1"
  printf '%s' "$HTTP_BODY" | jq -c '{total: (.total // -1), roles: ([.users[]?.role] | sort)}' 2>/dev/null || echo '{"total":-1,"roles":[]}'
}

one_admin() { [ "$(users_json "$1")" = '{"total":1,"roles":["admin"]}' ]; }

signup_code() { # EMAIL -> status of a signup attempt
  http POST /api/v1/auths/signup "$(jq -cn --arg e "$1" '{email:$e,password:"stranger-12345678",name:"Stranger"}')" ""
  printf '%s' "$HTTP_CODE"
}

signup_open() { # -> "true"/"false" from /api/config
  http GET /api/config "" ""
  printf '%s' "$HTTP_BODY" | jq -r '.features.enable_signup' 2>/dev/null || echo parse-error
}

token_works() { # TOKEN -> status of a protected listing
  http GET "/api/v1/users/" "" "$1"
  printf '%s' "$HTTP_CODE"
}

listener_opened() { app_logs | grep -q 'Started server process\|Uvicorn running'; }

# log_clean NAME VALUE...: after a start, the log must not contain any
# bound or generated value. Called after every start with every value in
# play at that point: both admin passwords, both provider keys, the
# over-long password, the session key file's content and the bound
# WEBUI_SECRET_KEY value.
log_clean() {
  local name=$1 ok=true v log
  shift
  log=$(app_logs)
  for v in "$@"; do
    [ -n "$v" ] || continue
    if printf '%s' "$log" | grep -qF -- "$v"; then ok=false; echo "  log contains a bound value"; fi
  done
  report "$name: no bound or generated value in the log" $ok
}
verify_lines() { app_logs | grep -cF "$VERIFY_LINE" || true; }
marker_exists() { docker exec "$APP" test -e /data/.dockhold/template 2>/dev/null; }

# wait_health_watching_port: like wait_health, but records the public
# port's answer before and after the install marker appears. Sets
# EARLY_ANSWER (any non-000 code seen while the marker was absent),
# MARKER_AT (seconds until the marker appeared) and WAITED.
wait_health_watching_port() {
  local i t0 code seen_marker=""
  EARLY_ANSWER=""
  MARKER_AT=""
  t0=$(date +%s.%N)
  for i in $(seq 1 1200); do
    app_running || return 1
    code=$(docker exec "$CURL" curl -s -m 3 -o /dev/null -w '%{http_code}' "$URL/health" 2>/dev/null) || true
    [ -n "$code" ] || code=000
    if [ -z "$seen_marker" ]; then
      if marker_exists; then
        seen_marker=yes
        MARKER_AT=$(printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)")
      elif [ "$code" != 000 ]; then
        EARLY_ANSWER=$code
      fi
    fi
    if [ "$code" = 200 ]; then
      WAITED=$(printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)")
      return 0
    fi
    sleep 0.5
  done
  return 1
}
EARLY_ANSWER=""
MARKER_AT=""

# A refused-start case: the container must exit 1 with exactly one log line.
expect_one_line_refusal() { # NAME EXPECTED_LINE [docker run args...]
  local name=$1 expected=$2
  shift 2
  start_app "$@"
  local code lines ok=true
  code=$(wait_exit)
  lines=$(app_logs | wc -l | tr -d ' ')
  [ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
  [ "$lines" = 1 ] || { ok=false; echo "  log lines: $lines (want 1)"; }
  [ "$(app_logs)" = "$expected" ] || { ok=false; echo "  log line differs from the expected refusal"; }
  report "$name" $ok
}

# make_pdf FILE TEXT: a one-page PDF with one line of text and a correct
# cross-reference table, so the PDF reader does not have to repair it.
make_pdf() {
  local out=$1 text=$2
  local LC_ALL=C
  local content="BT /F1 12 Tf 50 750 Td ($text) Tj ET"
  local objs=(
    "<< /Type /Catalog /Pages 2 0 R >>"
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
    "<< /Length ${#content} >>"$'\n'"stream"$'\n'"$content"$'\n'"endstream"
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
  )
  local body="%PDF-1.4"$'\n' offsets=() i=1 obj off xref
  for obj in "${objs[@]}"; do
    offsets+=("${#body}")
    body+="$i 0 obj"$'\n'"$obj"$'\n'"endobj"$'\n'
    i=$((i + 1))
  done
  xref=${#body}
  body+="xref"$'\n'"0 6"$'\n'"0000000000 65535 f "$'\n'
  for off in "${offsets[@]}"; do body+="$(printf '%010d 00000 n ' "$off")"$'\n'; done
  body+="trailer"$'\n'"<< /Size 6 /Root 1 0 R >>"$'\n'"startxref"$'\n'"$xref"$'\n'"%%EOF"$'\n'
  printf '%s' "$body" > "$out"
}

# ---------------------------------------------------------------------------
echo "==== open-webui-starter smoke test: $IMAGE"
docker network create --internal "$NET" >/dev/null
docker run -d --name "$CURL" --network "$NET" --entrypoint sh "$CURL_IMAGE" -c 'sleep 100000' >/dev/null
PINNED=$(docker run --rm --entrypoint cat "$IMAGE" /app/package.json | jq -r .version)
info "pinned Open WebUI version: $PINNED"
make_pdf "$BASE/probe.pdf" "$PDF_TEXT"
docker cp "$BASE/probe.pdf" "$CURL:/tmp/probe.pdf" >/dev/null

EMAIL_A="Owner-$(rand_hex 4)@example.com"
EMAIL_A_LC=$(printf '%s' "$EMAIL_A" | tr 'A-Z' 'a-z')
EMAIL_B="second-$(rand_hex 4)@example.com"
PASS_1="pw1-$(rand_hex 8)"
PASS_2="pw2-$(rand_hex 8)"
KEY_1="sk-key1-$(rand_hex 12)"
KEY_2="sk-key2-$(rand_hex 12)"
LONG_PW="L$(rand_hex 36)"   # 73 bytes: passes a naive check, bcrypt upstream refuses it
SECRETS_A=(-e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e "WEBUI_ADMIN_PASSWORD=$PASS_1" -e "OPENAI_API_KEY=$KEY_1")
# Every value that must never appear in a log; the session key is added
# once the first start has generated it.
ALL_VALUES=("$PASS_1" "$PASS_2" "$KEY_1" "$KEY_2" "$LONG_PW")
APP_URL="https://open-webui-$(rand_hex 3).dockhold.app"
ADDR=(-e "DOCKHOLD_APP_URL=$APP_URL" -e "DOCKHOLD_APP_HOSTNAME=${APP_URL#https://}")

# ---------------------------------------------------------------------------
echo "==== Storage refusals"
D_RO=$(new_datadir)
expect_one_line_refusal "DATA_DIR unset: one line, exit 1" "$STORAGE_LINE" "${SECRETS_A[@]}"
expect_one_line_refusal "DATA_DIR empty: one line, exit 1" "$STORAGE_LINE" -e DATA_DIR= "${SECRETS_A[@]}"
expect_one_line_refusal "DATA_DIR missing path: one line, exit 1" "$STORAGE_LINE" -e DATA_DIR=/nowhere "${SECRETS_A[@]}"
expect_one_line_refusal "DATA_DIR relative path: one line, exit 1" "$STORAGE_LINE" -e DATA_DIR=data "${SECRETS_A[@]}"
expect_one_line_refusal "DATA_DIR read-only mount: one line, exit 1" "$STORAGE_LINE" -e DATA_DIR=/data -v "$D_RO:/data:ro" "${SECRETS_A[@]}"

# ---------------------------------------------------------------------------
echo "==== Refused variable"
D_SEC=$(new_datadir)
expect_one_line_refusal "DATABASE_URL set: refused with one line, exit 1" "$DB_LINE" \
  -e DATA_DIR=/data -v "$D_SEC:/data" -e "DATABASE_URL=postgres://user:pw@db.example:5432/app" "${SECRETS_A[@]}"

# ---------------------------------------------------------------------------
echo "==== Secret refusals"
secret_refusal() { # NAME MUST_CONTAIN MUST_NOT_CONTAIN [docker run args...]
  local name=$1 must=$2 mustnot=$3
  shift 3
  start_app -e DATA_DIR=/data -v "$D_SEC:/data" "$@"
  local code ok=true log
  code=$(wait_exit)
  log=$(app_logs)
  [ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
  [ "$(printf '%s\n' "$log" | wc -l | tr -d ' ')" = 1 ] || { ok=false; echo "  more than one log line"; }
  printf '%s' "$log" | grep -qF -- "$must" || { ok=false; echo "  log does not say: $must"; }
  printf '%s' "$log" | grep -q 'Variables tab\|Settings > Secrets' || { ok=false; echo "  log does not say where to fix it"; }
  if [ -n "$mustnot" ] && printf '%s' "$log" | grep -qF -- "$mustnot"; then ok=false; echo "  log contains a secret value"; fi
  if listener_opened; then ok=false; echo "  listener opened"; fi
  [ "$(as_root "$D_SEC" 'test -e /data/.dockhold && echo yes || echo no')" = no ] || { ok=false; echo "  a refused start wrote the template folder"; }
  report "$name" $ok
}
secret_refusal "WEBUI_ADMIN_EMAIL missing: names it, exit 1, no value, no listener" "WEBUI_ADMIN_EMAIL is missing" "$PASS_1" \
  -e "WEBUI_ADMIN_PASSWORD=$PASS_1" -e "OPENAI_API_KEY=$KEY_1"
secret_refusal "WEBUI_ADMIN_PASSWORD empty: names it, exit 1, no value, no listener" "WEBUI_ADMIN_PASSWORD is missing" "$KEY_1" \
  -e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e WEBUI_ADMIN_PASSWORD= -e "OPENAI_API_KEY=$KEY_1"
secret_refusal "OPENAI_API_KEY missing: names it, exit 1, no value, no listener" "OPENAI_API_KEY is missing" "$PASS_1" \
  -e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e "WEBUI_ADMIN_PASSWORD=$PASS_1"
secret_refusal "two missing: names both with 'are', exit 1, no listener" "WEBUI_ADMIN_EMAIL and OPENAI_API_KEY are missing" "$PASS_1" \
  -e "WEBUI_ADMIN_PASSWORD=$PASS_1"
secret_refusal "all three missing: names all three, exit 1, no listener" "WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD and OPENAI_API_KEY are missing" ""
secret_refusal "admin email without @: refused, exit 1, no value, no listener" "WEBUI_ADMIN_EMAIL is not an email address" "$PASS_1" \
  -e "WEBUI_ADMIN_EMAIL=owner.example.com" -e "WEBUI_ADMIN_PASSWORD=$PASS_1" -e "OPENAI_API_KEY=$KEY_1"
secret_refusal "7-character password: refused, exit 1, no value, no listener" "WEBUI_ADMIN_PASSWORD must be 8 to 72" "q7zK2m9" \
  -e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e "WEBUI_ADMIN_PASSWORD=q7zK2m9" -e "OPENAI_API_KEY=$KEY_1"
secret_refusal "73-byte password (upstream's bcrypt would reject it): refused, exit 1, no value, no listener" "WEBUI_ADMIN_PASSWORD must be 8 to 72" "$LONG_PW" \
  -e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e "WEBUI_ADMIN_PASSWORD=$LONG_PW" -e "OPENAI_API_KEY=$KEY_1"

# ---------------------------------------------------------------------------
echo "==== First start"
D_MAIN=$(new_datadir)
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
wait_health_watching_port || ok=false
report "first start: /health answers 200" $ok
[ "$ok" = true ] && info "first start on fresh storage at --memory $MEM: marker after ${MARKER_AT}s (loopback verify pass), public /health after ${WAITED}s; memory.peak so far: $(mem_peak_mib) MiB"
ok=true
[ -z "$EARLY_ANSWER" ] || { ok=false; echo "  the public port answered $EARLY_ANSWER before the marker existed"; }
[ -n "$MARKER_AT" ] || { ok=false; echo "  marker never seen"; }
report "first start: public port refused every connection until the install marker existed, then answered" $ok
ok=true
[ "$(verify_lines)" = 1 ] || { ok=false; echo "  verify line count: $(verify_lines) (want 1)"; }
[ "$(app_logs | grep -c 'Started server process')" = 2 ] || { ok=false; echo "  server starts in the log: $(app_logs | grep -c 'Started server process') (want 2: loopback, then public)"; }
report "first start: exactly one loopback verify pass, two server starts in the log" $ok

http GET / "" ""
ok=true
[ "$HTTP_CODE" = 200 ] || ok=false
printf '%s' "$HTTP_BODY" | grep -qi '<html' || ok=false
report "first start: / returns HTML" $ok

TOK_A1=$(login "$EMAIL_A_LC" "$PASS_1")
report "first start: signin with the admin secrets returns a token" "$([ -n "$TOK_A1" ] && echo true || echo false)"
if [ -n "$TOK_A1" ]; then
  payload=$(printf '%s' "$TOK_A1" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="$payload="; done
  LIFE=$(printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '(.exp - .iat)' 2>/dev/null || echo "?")
  info "token lifetime from its claims: ${LIFE}s (JWT_EXPIRES_IN=7d is 604800)"
fi

report "first start: exactly one user, and it is the admin ($(users_json "$TOK_A1"))" "$(one_admin "$TOK_A1" && echo true || echo false)"

SC=$(signup_code "stranger-$(rand_hex 3)@example.com")
ok=true
[[ "$SC" =~ ^4 ]] || { ok=false; echo "  signup returned $SC"; }
[ "$(signup_open)" = false ] || { ok=false; echo "  /api/config says enable_signup=$(signup_open)"; }
one_admin "$TOK_A1" || { ok=false; echo "  a user was added"; }
report "first start: signup refused ($SC) and /api/config reports signup disabled" $ok

ok=true
[ "$(docker exec "$APP" stat -c %a /data/.dockhold 2>/dev/null)" = 700 ] || { ok=false; echo "  template dir mode: $(docker exec "$APP" stat -c %a /data/.dockhold 2>&1)"; }
[ "$(docker exec "$APP" stat -c %a /data/.dockhold/webui-secret-key 2>/dev/null)" = 600 ] || { ok=false; echo "  key file mode: $(docker exec "$APP" stat -c %a /data/.dockhold/webui-secret-key 2>&1)"; }
KEY_CONTENT=$(docker exec "$APP" cat /data/.dockhold/webui-secret-key 2>/dev/null || true)
[ "${#KEY_CONTENT}" -ge 32 ] || { ok=false; echo "  key file content length ${#KEY_CONTENT}"; }
printf '%s' "$KEY_CONTENT" | grep -Eqx '[A-Za-z0-9+/]{32,}={0,2}' || { ok=false; echo "  key file is not one base64 line"; }
[ "$(docker exec "$APP" cat /data/.dockhold/template 2>/dev/null)" = "open-webui-starter $PINNED" ] || { ok=false; echo "  marker content: $(docker exec "$APP" cat /data/.dockhold/template 2>&1)"; }
[ "$(docker exec "$APP" stat -c %a /data/.dockhold/home 2>/dev/null)" = 700 ] || { ok=false; echo "  home dir mode: $(docker exec "$APP" stat -c %a /data/.dockhold/home 2>&1)"; }
[ "$(as_root "$D_MAIN" 'test -e /data/.webui_secret_key && echo yes || echo no')" = no ] || { ok=false; echo "  upstream wrote its own key file next to the data"; }
report "first start: session key file (600, 32+ base64 chars), template marker, home dir, all under .dockhold (700)" $ok

ALL_VALUES+=("$KEY_CONTENT")
log_clean "first start" "${ALL_VALUES[@]}"
info "upstream logs the admin email itself: $(app_logs | grep -cF -- "$EMAIL_A") line(s) mention it"

ok=true
http GET /api/models "" "$TOK_A1"
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  /api/models returned $HTTP_CODE"; }
http GET /api/version/updates "" "$TOK_A1"
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  /api/version/updates returned $HTTP_CODE"; }
sleep 1
app_running || { ok=false; echo "  app died after the outbound calls"; }
http GET /health "" ""
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  health $HTTP_CODE after the outbound calls"; }
app_logs | grep -q 'Connection error\|Cannot connect to host' || { ok=false; echo "  no failed outbound call in the log (is the network really internal?)"; }
report "first start: provider model list and release check fail without network, app stays up" $ok

ok=true
http GET /static/favicon.png "" "" -o /dev/null
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  favicon $HTTP_CODE"; }
http GET /static/splash.png "" "" -o /dev/null
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  splash $HTTP_CODE"; }
PERM=$(app_logs | grep -c 'Permission denied' || true)
[ "$PERM" = 0 ] || { ok=false; echo "  $PERM 'Permission denied' lines in the log"; }
report "first start: favicon and splash served, no 'Permission denied' lines ($PERM)" $ok

http_upload "/api/v1/files/?process=true" "$TOK_A1" /tmp/probe.pdf
ok=true
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  upload returned $HTTP_CODE: $(printf '%s' "$HTTP_BODY" | head -c 200)"; }
FILE_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.id // empty')
STATUS=""
for i in $(seq 1 60); do
  http GET "/api/v1/files/$FILE_ID" "" "$TOK_A1"
  STATUS=$(printf '%s' "$HTTP_BODY" | jq -r '.data.status // empty')
  [ "$STATUS" = completed ] && break
  [ "$STATUS" = failed ] && break
  sleep 1
done
[ "$STATUS" = completed ] || { ok=false; echo "  file status: $STATUS"; }
printf '%s' "$HTTP_BODY" | jq -r '.data.content // ""' | grep -qF -- "zebra quantum pineapple" || { ok=false; echo "  extracted text does not contain the probe sentence"; }
app_logs | grep -qi 'embeddings generated' || { ok=false; echo "  no embedding step in the log"; }
if app_logs | grep -qi 'huggingface.co\|Downloading'; then ok=false; echo "  a download was attempted"; fi
report "first start: one-page PDF upload offline is extracted and embedded with the bundled model, no download attempted" $ok
info "memory.peak after cold start, signin and one PDF upload at --memory $MEM: $(mem_peak_mib) MiB"
sleep 10
info "memory.current after 10 s idle: $(mem_now_mib) MiB"

# ---------------------------------------------------------------------------
echo "==== Second start on the same storage"
stop_app
FIRST_WAITED=$WAITED
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
wait_health || ok=false
report "second start: /health answers 200" $ok
[ "$ok" = true ] && info "second start (established install) to /health: ${WAITED}s"
ok=true
[ "$(verify_lines)" = 0 ] || { ok=false; echo "  verify line count: $(verify_lines) (want 0)"; }
[ "$(app_logs | grep -c 'Started server process')" = 1 ] || { ok=false; echo "  server starts: $(app_logs | grep -c 'Started server process') (want 1)"; }
# Not doubled: the established path must take well under the first start.
[ "$(echo "$WAITED * 1.5 < $FIRST_WAITED" | bc)" = 1 ] || { ok=false; echo "  second start ${WAITED}s is not clearly shorter than the first ${FIRST_WAITED}s"; }
report "second start: established install skips the loopback pass (no verify line, one server start, ${WAITED}s vs ${FIRST_WAITED}s)" $ok
ok=true
TW=$(token_works "$TOK_A1")
report "second start: token from the first start still works ($TW)" "$([ "$TW" = 200 ] && echo true || echo false)"
TOK_A2=$(login "$EMAIL_A_LC" "$PASS_1")
[ -n "$TOK_A2" ] || ok=false
report "second start: admin logs in" $ok
report "second start: still exactly one admin" "$(one_admin "$TOK_A2" && echo true || echo false)"
SC=$(signup_code "stranger-$(rand_hex 3)@example.com")
report "second start: signup still refused ($SC)" "$([[ "$SC" =~ ^4 ]] && [ "$(signup_open)" = false ] && echo true || echo false)"
[ "$(as_root "$D_MAIN" 'cat /data/.dockhold/webui-secret-key')" = "$KEY_CONTENT" ] && k=true || k=false
report "second start: key file unchanged" $k
log_clean "second start" "${ALL_VALUES[@]}"

# ---------------------------------------------------------------------------
echo "==== Settings after the first start: which side wins"
# Every seeded setting changed at once, plus different (valid) admin values.
stop_app
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${ADDR[@]}" \
  -e "WEBUI_ADMIN_EMAIL=$EMAIL_B" -e "WEBUI_ADMIN_PASSWORD=$PASS_2" -e "OPENAI_API_KEY=$KEY_2" \
  -e OPENAI_API_BASE_URL=https://openrouter.ai/api/v1 -e ENABLE_OLLAMA_API=true -e ENABLE_SIGNUP=true \
  -e WEBUI_URL=https://other.example -e JWT_EXPIRES_IN=1d -e DEFAULT_USER_ROLE=user
ok=true
wait_health || ok=false
TOK_A3=$(login "$EMAIL_A_LC" "$PASS_1")
[ -n "$TOK_A3" ] || { ok=false; echo "  first admin no longer logs in"; }
[ -z "$(login "$EMAIL_B" "$PASS_2")" ] || { ok=false; echo "  changed admin variables created a login"; }
one_admin "$TOK_A3" || { ok=false; echo "  user list changed: $(users_json "$TOK_A3")"; }
report "changed WEBUI_ADMIN_*: ignored on an existing installation (Open WebUI owns the account)" $ok

http GET /openai/config "" "$TOK_A3"
BASEURLS=$(printf '%s' "$HTTP_BODY" | jq -c '.OPENAI_API_BASE_URLS')
KEYS_MATCH_FIRST=$(printf '%s' "$HTTP_BODY" | jq -r --arg k "$KEY_1" '.OPENAI_API_KEYS == [$k]')
report "changed OPENAI_API_BASE_URL and OPENAI_API_KEY: app kept the first values ($BASEURLS, first key: $KEYS_MATCH_FIRST)" \
  "$([ "$BASEURLS" = '["https://api.openai.com/v1"]' ] && [ "$KEYS_MATCH_FIRST" = true ] && echo true || echo false)"
http GET /ollama/config "" "$TOK_A3"
OLL=$(printf '%s' "$HTTP_BODY" | jq -r '.ENABLE_OLLAMA_API')
http GET /api/v1/auths/admin/config "" "$TOK_A3"
ADM=$(printf '%s' "$HTTP_BODY" | jq -c '{ENABLE_SIGNUP, WEBUI_URL, JWT_EXPIRES_IN, DEFAULT_USER_ROLE}')
report "changed ENABLE_OLLAMA_API, ENABLE_SIGNUP, WEBUI_URL, JWT_EXPIRES_IN, DEFAULT_USER_ROLE: app kept the first values (ollama=$OLL, $ADM)" \
  "$([ "$OLL" = false ] && [ "$ADM" = "{\"ENABLE_SIGNUP\":false,\"WEBUI_URL\":\"$APP_URL\",\"JWT_EXPIRES_IN\":\"7d\",\"DEFAULT_USER_ROLE\":\"pending\"}" ] && echo true || echo false)"
SC=$(signup_code "stranger-$(rand_hex 3)@example.com")
report "ENABLE_SIGNUP=true on restart: signup still refused ($SC)" "$([[ "$SC" =~ ^4 ]] && echo true || echo false)"
log_clean "settings-changed start" "${ALL_VALUES[@]}"

# ---------------------------------------------------------------------------
echo "==== Forged proxy headers"
FORGED=(-H 'X-Forwarded-For: 127.0.0.1' -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Host: attacker.example' -H 'Host: attacker.example')
ok=true
http GET "/api/v1/users/" "" "" "${FORGED[@]}"
[[ "$HTTP_CODE" =~ ^4 ]] || { ok=false; echo "  listing users with forged headers returned $HTTP_CODE"; }
http GET "/api/v1/auths/" "" "" "${FORGED[@]}"
[[ "$HTTP_CODE" =~ ^4 ]] || { ok=false; echo "  session lookup with forged headers returned $HTTP_CODE"; }
http POST /api/v1/auths/signup '{"email":"forged@example.com","password":"forged-12345678","name":"F"}' "" "${FORGED[@]}"
[[ "$HTTP_CODE" =~ ^4 ]] || { ok=false; echo "  signup with forged headers returned $HTTP_CODE"; }
http GET /openai/config "" "" "${FORGED[@]}"
[[ "$HTTP_CODE" =~ ^4 ]] || { ok=false; echo "  provider config with forged headers returned $HTTP_CODE"; }
report "forged X-Forwarded-* and Host headers: protected endpoints still refuse without a token" $ok
# What the headers do change: upstream starts uvicorn with
# --forwarded-allow-ips "*", so the client address in the access log is
# whatever X-Forwarded-For says. Recorded, not asserted: behind Dockhold
# only the edge reaches the app, and what the edge does with a client's
# own X-Forwarded-For is the edge's business, not this image's.
http GET "/api/v1/users/" "" "" -H 'X-Forwarded-For: 203.0.113.9'
FWD_SEEN=$(app_logs | grep -F '"GET /api/v1/users/ HTTP/1.1" 401' | tail -n 1 | grep -o '[0-9.]*:[0-9]* - "GET' | cut -d' ' -f1)
info "with X-Forwarded-For: 203.0.113.9 the access log records the client as ${FWD_SEEN:-?} (upstream trusts forwarded headers from any address)"

# ---------------------------------------------------------------------------
echo "==== Session key file damaged or missing"
stop_app
as_root "$D_MAIN" ': > /data/.dockhold/webui-secret-key'
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
code=$(wait_exit)
[ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
[ "$(app_logs)" = "$KEY_DAMAGED_LINE" ] || { ok=false; echo "  log differs from the damaged-key line: $(app_logs | head -3)"; }
[ "$(as_root "$D_MAIN" 'wc -c < /data/.dockhold/webui-secret-key' | tr -d ' ')" = 0 ] || { ok=false; echo "  the empty key file was overwritten"; }
report "key file emptied: refused with the damaged-key line, exit 1, file not overwritten" $ok

as_root "$D_MAIN" 'printf "not a key\nsecond line\n" > /data/.dockhold/webui-secret-key'
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
code=$(wait_exit)
[ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
[ "$(app_logs)" = "$KEY_DAMAGED_LINE" ] || { ok=false; echo "  log differs from the damaged-key line"; }
[ "$(as_root "$D_MAIN" 'cat /data/.dockhold/webui-secret-key')" = "$(printf 'not a key\nsecond line')" ] || { ok=false; echo "  the malformed key file was overwritten"; }
report "key file malformed: refused with the damaged-key line, exit 1, file not overwritten" $ok

as_root "$D_MAIN" 'rm -f /data/.dockhold/webui-secret-key'
expect_one_line_refusal "key file deleted on an established install, no WEBUI_SECRET_KEY: refused with the missing-key line, exit 1" "$KEY_MISSING_LINE" \
  -e DATA_DIR=/data -v "$D_MAIN:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
[ "$(as_root "$D_MAIN" 'test -e /data/.dockhold/webui-secret-key && echo yes || echo no')" = no ] && r=true || r=false
report "key file deleted: the refusal did not create a new key" $r

start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${ADDR[@]}" "${SECRETS_A[@]}" -e "WEBUI_SECRET_KEY=$KEY_CONTENT"
ok=true
wait_health || ok=false
[ "$(token_works "$TOK_A1")" = 200 ] || { ok=false; echo "  token from the first start gets $(token_works "$TOK_A1") with the bound key"; }
[ -n "$(login "$EMAIL_A_LC" "$PASS_1")" ] || { ok=false; echo "  admin does not log in with the bound key"; }
[ "$(as_root "$D_MAIN" 'test -e /data/.dockhold/webui-secret-key && echo yes || echo no')" = no ] || { ok=false; echo "  a key file appeared while WEBUI_SECRET_KEY was bound"; }
report "key file deleted, WEBUI_SECRET_KEY bound to the old key: starts, the old token still works, no file written" $ok
log_clean "bound-key start" "${ALL_VALUES[@]}"
# Put the file back for anything that follows.
stop_app
as_root "$D_MAIN" "printf '%s\n' '$KEY_CONTENT' > /data/.dockhold/webui-secret-key && chown 1001:1001 /data/.dockhold/webui-secret-key && chmod 600 /data/.dockhold/webui-secret-key"

# ---------------------------------------------------------------------------
echo "==== Interrupted first start"
interrupted_case() { # LABEL KILL_FN
  local label=$1 killfn=$2 ok=true keybefore keyafter tok
  local d
  d=$(new_datadir)
  start_app -e DATA_DIR=/data -v "$d:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
  $killfn
  docker kill -s KILL "$APP" >/dev/null 2>&1 || true
  local phase="before the loopback server opened"
  if app_logs | grep -q 'authenticate_user'; then phase="admin created, marker not yet written"
  elif app_logs | grep -qF -- "$BOOTSTRAP_LINE"; then phase="after the admin was created"
  elif listener_opened; then phase="after the loopback server opened"; fi
  [ "$(as_root "$d" 'test -e /data/.dockhold/template && echo yes || echo no')" = no ] || { ok=false; echo "  a marker exists after a kill during the verify pass"; }
  keybefore=$(as_root "$d" 'cat /data/.dockhold/webui-secret-key 2>/dev/null || true')
  start_app -e DATA_DIR=/data -v "$d:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
  wait_health_watching_port || { ok=false; echo "  not healthy after the interrupted first start"; }
  [ -z "$EARLY_ANSWER" ] || { ok=false; echo "  public port answered $EARLY_ANSWER before the marker on the retry"; }
  [ "$(verify_lines)" = 1 ] || { ok=false; echo "  the retry did not run the verify pass"; }
  tok=$(login "$EMAIL_A_LC" "$PASS_1")
  [ -n "$tok" ] || { ok=false; echo "  admin does not log in"; }
  one_admin "$tok" || { ok=false; echo "  users: $(users_json "$tok")"; }
  [[ "$(signup_code "stranger-$(rand_hex 3)@example.com")" =~ ^4 ]] || { ok=false; echo "  signup not refused"; }
  keyafter=$(as_root "$d" 'cat /data/.dockhold/webui-secret-key')
  if [ -n "$keybefore" ]; then
    [ "$keybefore" = "$keyafter" ] || { ok=false; echo "  the key written before the kill was replaced"; }
  fi
  report "interrupted first start ($label, $phase): healthy, one admin, signup refused, key kept" $ok
  log_clean "interrupted first start ($label) retry" "${ALL_VALUES[@]}" "$keyafter"
  stop_app
}
kill_1s() { sleep 1; }
kill_5s() { sleep 5; }
kill_after_bootstrap() {
  local i
  for i in $(seq 1 1200); do
    app_logs | grep -qF -- "$BOOTSTRAP_LINE" && return 0
    app_running || return 0
    sleep 0.1
  done
}
# The loopback server is not reachable from the helper, so "health first
# answers" is read from the log. Upstream's logger drops uvicorn's own
# "startup complete" line; the last line of its startup sequence is the
# scheduler worker's, and /health answers right after it. The sign-in line
# comes next: health has answered, the start script is signing in, the
# marker is not yet written.
kill_at_loopback_health() {
  local i
  for i in $(seq 1 1200); do
    app_logs | grep -q 'Scheduler worker started' && return 0
    app_running || return 0
    sleep 0.1
  done
}
kill_during_signin() {
  local i
  for i in $(seq 1 1200); do
    app_logs | grep -q 'authenticate_user' && return 0
    app_running || return 0
    sleep 0.1
  done
}
interrupted_case "KILL at 1 s" kill_1s
interrupted_case "KILL at 5 s" kill_5s
interrupted_case "KILL right after the bootstrap log line" kill_after_bootstrap
interrupted_case "KILL when the loopback health first answers" kill_at_loopback_health
interrupted_case "KILL during the loopback sign-in" kill_during_signin

# The platform's stop signal during the pass: the start script forwards it
# to the loopback server, waits for it, and exits 143. No marker, key kept,
# and the next start comes up. The signal is sent by phase, not by the
# clock: once the log shows the verify line and the loopback server's own
# start line, and only while the marker does not exist yet. A slow or fast
# machine changes when that is, not whether it happens.
D_TERM=$(new_datadir)
start_app -e DATA_DIR=/data -v "$D_TERM:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
for i in $(seq 1 2400); do
  app_running || break
  [ "$(verify_lines)" -ge 1 ] && listener_opened && break
  sleep 0.1
done
if marker_exists; then
  unknown "SIGTERM during the verify pass: the marker already existed when the loopback server's start line appeared, so the signal could not be sent inside the pass on this machine"
  stop_app
  KEY_TERM=""
else
  T0=$(date +%s.%N)
  docker kill -s TERM "$APP" >/dev/null 2>&1 || true
  code=$(timeout 90 docker wait "$APP" 2>/dev/null || true)
  TERM_TO_EXIT=$(printf '%.1f' "$(echo "$(date +%s.%N) - $T0" | bc)")
  ok=true
  [ -n "$code" ] || { ok=false; code="still running after 90 s"; docker kill "$APP" >/dev/null 2>&1 || true; }
  [ "$code" = 143 ] || { ok=false; echo "  exit code after SIGTERM: $code (want 143)"; }
  [ "$(as_root "$D_TERM" 'test -e /data/.dockhold/template && echo yes || echo no')" = no ] || { ok=false; echo "  a marker exists after SIGTERM during the pass"; }
  KEY_TERM=$(as_root "$D_TERM" 'cat /data/.dockhold/webui-secret-key 2>/dev/null || true')
  [ -n "$KEY_TERM" ] || { ok=false; echo "  no key file after SIGTERM"; }
  report "SIGTERM during the verify pass (loopback server started, marker absent): exit 143, no marker, key file present" $ok
  info "SIGTERM to container exit during the verify pass: ${TERM_TO_EXIT}s"
fi
start_app -e DATA_DIR=/data -v "$D_TERM:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
wait_health_watching_port || { ok=false; echo "  not healthy after SIGTERM retry"; }
[ -z "$EARLY_ANSWER" ] || { ok=false; echo "  public port answered $EARLY_ANSWER before the marker"; }
TOK_T=$(login "$EMAIL_A_LC" "$PASS_1")
[ -n "$TOK_T" ] || { ok=false; echo "  admin does not log in"; }
one_admin "$TOK_T" || { ok=false; echo "  users: $(users_json "$TOK_T")"; }
if [ -n "$KEY_TERM" ]; then
  [ "$(as_root "$D_TERM" 'cat /data/.dockhold/webui-secret-key')" = "$KEY_TERM" ] || { ok=false; echo "  key replaced on the retry"; }
fi
report "SIGTERM retry: healthy, one admin, key kept" $ok
log_clean "SIGTERM retry" "${ALL_VALUES[@]}" "$KEY_TERM"
stop_app

# ---------------------------------------------------------------------------
echo "==== Bootstrap failure that passes the value checks"
# A database whose user table refuses inserts: upstream's admin bootstrap
# fails after every check in the start script has passed, and upstream
# would carry on with no admin. The schema is created first by importing
# upstream's config module (that runs the migrations without starting the
# app; the import insists on a WEBUI_SECRET_KEY, so a throwaway one is
# set for that command only), then a trigger blocks inserts into the user
# table.
D_FAULT=$(new_datadir)
FAULT_ENV=(--user 1001:1001 --network none -e DATA_DIR=/data -e WEBUI_SECRET_KEY=setup-only-throwaway -v "$D_FAULT:/data" --entrypoint python3)
docker run --rm -i "${FAULT_ENV[@]}" "$IMAGE" - >/dev/null 2>&1 <<'PYFAULT' || echo "  (fault setup exited non-zero)"
import os, sqlite3
import open_webui.config  # runs the migrations at import, without starting the app
db = sqlite3.connect(os.path.join(os.environ["DATA_DIR"], "webui.db"))
db.execute("CREATE TRIGGER block_users BEFORE INSERT ON user BEGIN SELECT RAISE(ABORT, 'blocked'); END")
db.commit()
PYFAULT
[ "$(as_root "$D_FAULT" 'test -f /data/webui.db && echo yes || echo no')" = yes ] || echo "  (no webui.db after the fault setup)"
start_app -e DATA_DIR=/data -v "$D_FAULT:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
EARLY=""
for i in $(seq 1 1200); do
  app_running || break
  # A marker means the fault did not bite and the app is about to serve;
  # stop watching rather than wait out the whole limit.
  marker_exists && { echo "  the marker appeared: the bootstrap did not fail"; ok=false; docker kill "$APP" >/dev/null 2>&1; break; }
  code=$(docker exec "$CURL" curl -s -m 3 -o /dev/null -w '%{http_code}' "$URL/health" 2>/dev/null) || true
  [ -n "$code" ] || code=000
  [ "$code" = 000 ] || EARLY=$code
  sleep 0.5
done
code=$(wait_exit)
[ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
[ -z "$EARLY" ] || { ok=false; echo "  public port answered $EARLY"; }
[ "$(app_logs | tail -n 1)" = "$NO_ADMIN_LINE" ] || { ok=false; echo "  last log line is not the no-admin refusal: $(app_logs | tail -n 1 | cut -c1-120)"; }
app_logs | grep -q 'Error creating admin account' || { ok=false; echo "  upstream did not report the bootstrap failure (is the fault in place?)"; }
[ "$(as_root "$D_FAULT" 'test -e /data/.dockhold/template && echo yes || echo no')" = no ] || { ok=false; echo "  a marker was written"; }
report "bootstrap fails after the checks (user table refuses inserts): no-admin line last, exit 1, no marker, public port never answered" $ok
log_clean "bootstrap failure" "${ALL_VALUES[@]}" "$(as_root "$D_FAULT" 'cat /data/.dockhold/webui-secret-key 2>/dev/null || true')"
docker run --rm -i "${FAULT_ENV[@]}" "$IMAGE" - >/dev/null 2>&1 <<'PYFAULT' || echo "  (fault removal exited non-zero)"
import os, sqlite3
db = sqlite3.connect(os.path.join(os.environ["DATA_DIR"], "webui.db"))
db.execute("DROP TRIGGER block_users")
db.commit()
PYFAULT
start_app -e DATA_DIR=/data -v "$D_FAULT:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
wait_health_watching_port || { ok=false; echo "  not healthy after removing the fault"; }
[ -z "$EARLY_ANSWER" ] || { ok=false; echo "  public port answered $EARLY_ANSWER before the marker"; }
TOK_F=$(login "$EMAIL_A_LC" "$PASS_1")
[ -n "$TOK_F" ] || { ok=false; echo "  admin does not log in"; }
one_admin "$TOK_F" || { ok=false; echo "  users: $(users_json "$TOK_F")"; }
[[ "$(signup_code "stranger-$(rand_hex 3)@example.com")" =~ ^4 ]] || { ok=false; echo "  signup not refused"; }
report "fault removed: next start creates the admin, logs in, one admin, signup refused" $ok
log_clean "fault removed" "${ALL_VALUES[@]}" "$(as_root "$D_FAULT" 'cat /data/.dockhold/webui-secret-key 2>/dev/null || true')"
stop_app

# ---------------------------------------------------------------------------
echo "==== Established install whose user table is empty"
# Marker and key present, but the database has no accounts (a restore of
# an empty database, or one emptied by hand) and the insert fault is back:
# the pass must run on the marker alone being present, refuse, and keep
# the port closed; without the fault the admin is created again.
docker run --rm -i "${FAULT_ENV[@]}" "$IMAGE" - >/dev/null 2>&1 <<'PYFAULT' || echo "  (empty-users setup exited non-zero)"
import os, sqlite3
db = sqlite3.connect(os.path.join(os.environ["DATA_DIR"], "webui.db"))
db.execute("DELETE FROM auth")
db.execute("DELETE FROM user")
db.execute("CREATE TRIGGER block_users BEFORE INSERT ON user BEGIN SELECT RAISE(ABORT, 'blocked'); END")
db.commit()
PYFAULT
[ "$(as_root "$D_FAULT" 'test -e /data/.dockhold/template && echo yes || echo no')" = yes ] || echo "  (control: the marker is missing before the case)"
start_app -e DATA_DIR=/data -v "$D_FAULT:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
EARLY=""
for i in $(seq 1 1200); do
  app_running || break
  code=$(docker exec "$CURL" curl -s -m 3 -o /dev/null -w '%{http_code}' "$URL/health" 2>/dev/null) || true
  [ -n "$code" ] || code=000
  [ "$code" = 000 ] || { EARLY=$code; docker kill "$APP" >/dev/null 2>&1; break; }
  sleep 0.5
done
code=$(wait_exit)
[ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
[ -z "$EARLY" ] || { ok=false; echo "  public port answered $EARLY with no accounts in the database"; }
[ "$(verify_lines)" = 1 ] || { ok=false; echo "  verify line count $(verify_lines): the pass did not run on an empty user table"; }
[ "$(app_logs | tail -n 1)" = "$NO_ADMIN_LINE" ] || { ok=false; echo "  last log line: $(app_logs | tail -n 1 | cut -c1-120)"; }
report "marker present, user table empty, insert fault: the pass runs, refuses, public port never answered" $ok
docker run --rm -i "${FAULT_ENV[@]}" "$IMAGE" - >/dev/null 2>&1 <<'PYFAULT' || echo "  (fault removal exited non-zero)"
import os, sqlite3
db = sqlite3.connect(os.path.join(os.environ["DATA_DIR"], "webui.db"))
db.execute("DROP TRIGGER block_users")
db.commit()
PYFAULT
start_app -e DATA_DIR=/data -v "$D_FAULT:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
wait_health_watching_port || { ok=false; echo "  not healthy"; }
[ -z "$EARLY_ANSWER" ] || { ok=false; echo "  public port answered $EARLY_ANSWER before the pass finished"; }
[ "$(verify_lines)" = 1 ] || { ok=false; echo "  verify line count $(verify_lines)"; }
TOK_E=$(login "$EMAIL_A_LC" "$PASS_1")
[ -n "$TOK_E" ] || { ok=false; echo "  admin does not log in"; }
one_admin "$TOK_E" || { ok=false; echo "  users: $(users_json "$TOK_E")"; }
report "marker present, user table empty, fault removed: the pass runs, admin created, logs in" $ok
stop_app

# ---------------------------------------------------------------------------
echo "==== Restore without the marker on a populated database"
# The admin changed the password in the panel, then the storage was
# restored without .dockhold/template. The pass runs, the bound secrets no
# longer match the admin, and the refusal line has to be true for that.
# Binding the current password recovers.
D_RESTORE=$(new_datadir)
start_app -e DATA_DIR=/data -v "$D_RESTORE:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
wait_health || { ok=false; echo "  not healthy"; }
TOK_R=$(login "$EMAIL_A_LC" "$PASS_1")
http POST /api/v1/auths/update/password "$(jq -cn --arg p "$PASS_1" --arg n "$PASS_2" '{password:$p,new_password:$n}')" "$TOK_R"
[ "$HTTP_CODE" = 200 ] || { ok=false; echo "  password change returned $HTTP_CODE"; }
[ -n "$(login "$EMAIL_A_LC" "$PASS_2")" ] || { ok=false; echo "  control failed: the changed password does not log in"; }
report "populated database: admin changed the password in the panel" $ok
info "session after a password change inside Open WebUI (no session store): the token used for the change now gets $(token_works "$TOK_R") (200 = still valid, as the README says)"
stop_app
as_root "$D_RESTORE" 'rm -f /data/.dockhold/template'
start_app -e DATA_DIR=/data -v "$D_RESTORE:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
EARLY=""
for i in $(seq 1 1200); do
  app_running || break
  code=$(docker exec "$CURL" curl -s -m 3 -o /dev/null -w '%{http_code}' "$URL/health" 2>/dev/null) || true
  [ -n "$code" ] || code=000
  [ "$code" = 000 ] || { EARLY=$code; docker kill "$APP" >/dev/null 2>&1; break; }
  sleep 0.5
done
code=$(wait_exit)
[ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
[ -z "$EARLY" ] || { ok=false; echo "  public port answered $EARLY"; }
[ "$(app_logs | tail -n 1)" = "$NO_ADMIN_LINE" ] || { ok=false; echo "  last log line: $(app_logs | tail -n 1 | cut -c1-120)"; }
[ "$(as_root "$D_RESTORE" 'test -e /data/.dockhold/template && echo yes || echo no')" = no ] || { ok=false; echo "  a marker was written"; }
report "marker removed, bound password no longer matches: the pass refuses with the mismatch line, exit 1, no marker" $ok
log_clean "restore without marker, refused" "${ALL_VALUES[@]}"
start_app -e DATA_DIR=/data -v "$D_RESTORE:/data" "${ADDR[@]}" -e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e "WEBUI_ADMIN_PASSWORD=$PASS_2" -e "OPENAI_API_KEY=$KEY_1"
ok=true
wait_health_watching_port || { ok=false; echo "  not healthy with the current password bound"; }
[ -z "$EARLY_ANSWER" ] || { ok=false; echo "  public port answered $EARLY_ANSWER before the marker"; }
[ -n "$(login "$EMAIL_A_LC" "$PASS_2")" ] || { ok=false; echo "  admin does not log in"; }
[ "$(as_root "$D_RESTORE" 'test -e /data/.dockhold/template && echo yes || echo no')" = yes ] || { ok=false; echo "  marker not written"; }
report "current password bound: the pass signs in, marker written, healthy" $ok
log_clean "restore without marker, recovered" "${ALL_VALUES[@]}"
stop_app

# A database that cannot be opened at all (webui.db is a directory): the
# loopback server dies before it is healthy.
D_DIR=$(new_datadir)
as_root "$D_DIR" 'mkdir /data/webui.db && chown 1001:1001 /data/webui.db'
start_app -e DATA_DIR=/data -v "$D_DIR:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
code=$(wait_exit)
[ "$code" = 1 ] || { ok=false; echo "  exit code: $code (want 1)"; }
[ "$(app_logs | tail -n 1)" = "$STOPPED_LINE" ] || { ok=false; echo "  last log line: $(app_logs | tail -n 1 | cut -c1-120)"; }
[ "$(as_root "$D_DIR" 'test -e /data/.dockhold/template && echo yes || echo no')" = no ] || { ok=false; echo "  a marker was written"; }
report "database cannot be opened: loopback server dies, one line saying so, exit 1, no marker" $ok

# ---------------------------------------------------------------------------
echo "==== Upstream alone: what a failed admin bootstrap leaves behind (measurement, not a case)"
# The template refuses the 73-byte password before start (see above). This
# runs upstream's own start script with that password to record what the
# template is protecting against: whether ENABLE_SIGNUP=false keeps a
# stranger out when no admin was created.
D_UP=$(new_datadir)
docker rm -f "$APP" >/dev/null 2>&1 || true
docker run -d --name "$APP" --network "$NET" --network-alias owui \
  --user 1001:1001 --cap-drop ALL --security-opt no-new-privileges --memory "$MEM" --memory-swap "$MEM" \
  -e "PORT=$PORT" -e DATA_DIR=/data -v "$D_UP:/data" -e HOME=/data/home -e WEBUI_SECRET_KEY_FILE=/data/key \
  -e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e "WEBUI_ADMIN_PASSWORD=$LONG_PW" -e "OPENAI_API_KEY=$KEY_1" \
  -e ENABLE_SIGNUP=false -e ENABLE_OLLAMA_API=false --entrypoint bash "$IMAGE" start.sh >/dev/null
if wait_health; then
  UP_ERR=$(app_logs | grep -c 'Error creating admin account' || true)
  UP_EMAIL="stranger-$(rand_hex 3)@example.com"
  UP_SC=$(signup_code "$UP_EMAIL")
  UP_USERS=""
  if [ "$UP_SC" = 200 ]; then UP_USERS=$(users_json "$(login "$UP_EMAIL" "stranger-12345678")"); fi
  info "upstream with a 73-byte admin password and ENABLE_SIGNUP=false: bootstrap error lines: $UP_ERR; /api/config enable_signup=$(signup_open); a stranger's signup returned $UP_SC${UP_USERS:+, users afterwards: $UP_USERS}. So ENABLE_SIGNUP=false does not protect a no-admin start; the template's value checks do."
else
  info "upstream-alone measurement: the container did not become healthy"
fi
stop_app

# ---------------------------------------------------------------------------
echo "==== Cold start at 1 GB (measurement)"
D_1G=$(new_datadir)
MEM=1g
start_app -e DATA_DIR=/data -v "$D_1G:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
if wait_health; then
  TOK_1G=$(login "$EMAIL_A_LC" "$PASS_1")
  http_upload "/api/v1/files/?process=true" "$TOK_1G" /tmp/probe.pdf
  UP1G=$HTTP_CODE
  sleep 5
  info "at --memory 1g: first start (verify pass + public start) to /health ${WAITED}s; signin $([ -n "$TOK_1G" ] && echo ok || echo failed); PDF upload $UP1G; memory.peak $(mem_peak_mib) MiB; OOM-killed: $(app_oom); still running: $(app_running && echo yes || echo no)"
  log_clean "1 GB run" "${ALL_VALUES[@]}" "$(as_root "$D_1G" 'cat /data/.dockhold/webui-secret-key 2>/dev/null || true')"
else
  info "at --memory 1g: did not become healthy within the limit; OOM-killed: $(app_oom); exit code: $(docker inspect -f '{{.State.ExitCode}}' "$APP" 2>/dev/null)"
fi
stop_app
MEM=2g

# ---------------------------------------------------------------------------
echo "==== Summary: $PASS_COUNT passed, $FAIL_COUNT failed, $UNKNOWN_COUNT unknown"
[ "$FAIL_COUNT" -eq 0 ]
