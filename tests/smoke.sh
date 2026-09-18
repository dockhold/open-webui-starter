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
# and each cold start takes half a minute or more, so expect ten minutes.
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
STORAGE_LINE="This app keeps its data on App storage. Turn on App storage in the Size tab and redeploy."
DB_LINE="This template keeps Open WebUI's data on App storage and does not use the managed database yet. Turn the managed database off for this app and redeploy."
KEY_MISSING_LINE="The app's session key is missing from App storage. Restore it from your backup or bind WEBUI_SECRET_KEY to the previous value."
KEY_DAMAGED_LINE="The app's session key file on App storage is damaged. Bind WEBUI_SECRET_KEY to the previous key or restore the file from your backup; the file is never overwritten."
BOOTSTRAP_LINE="Admin account created successfully"
PDF_TEXT="Dockhold ingestion probe: zebra quantum pineapple harbor."

PASS_COUNT=0
FAIL_COUNT=0
HTTP_CODE=000
HTTP_BODY=""

pass() { echo "PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
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

# Prints the exit code once the container has exited, or "running".
wait_exit() {
  local i
  for i in $(seq 1 120); do
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
SECRETS_A=(-e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e "WEBUI_ADMIN_PASSWORD=$PASS_1" -e "OPENAI_API_KEY=$KEY_1")
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
  -e DATA_DIR=/data -v "$D_SEC:/data" -e "DATABASE_URL=postgres://user:pw@db.internal:5432/app" "${SECRETS_A[@]}"

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
  printf '%s' "$log" | grep -qF "$must" || { ok=false; echo "  log does not say: $must"; }
  printf '%s' "$log" | grep -q 'Variables tab\|Settings > Secrets' || { ok=false; echo "  log does not say where to fix it"; }
  if [ -n "$mustnot" ] && printf '%s' "$log" | grep -qF "$mustnot"; then ok=false; echo "  log contains a secret value"; fi
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
secret_refusal "all three missing: names all three, exit 1, no listener" "WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD and OPENAI_API_KEY is missing" ""
secret_refusal "admin email without @: refused, exit 1, no value, no listener" "WEBUI_ADMIN_EMAIL is not an email address" "$PASS_1" \
  -e "WEBUI_ADMIN_EMAIL=owner.example.com" -e "WEBUI_ADMIN_PASSWORD=$PASS_1" -e "OPENAI_API_KEY=$KEY_1"
secret_refusal "7-character password: refused, exit 1, no value, no listener" "WEBUI_ADMIN_PASSWORD must be 8 to 72" "q7zK2m9" \
  -e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e "WEBUI_ADMIN_PASSWORD=q7zK2m9" -e "OPENAI_API_KEY=$KEY_1"
LONG_PW="L$(rand_hex 36)"   # 73 bytes: passes a naive check, bcrypt upstream refuses it
secret_refusal "73-byte password (upstream's bcrypt would reject it): refused, exit 1, no value, no listener" "WEBUI_ADMIN_PASSWORD must be 8 to 72" "$LONG_PW" \
  -e "WEBUI_ADMIN_EMAIL=$EMAIL_A" -e "WEBUI_ADMIN_PASSWORD=$LONG_PW" -e "OPENAI_API_KEY=$KEY_1"

# ---------------------------------------------------------------------------
echo "==== First start"
D_MAIN=$(new_datadir)
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
wait_health || ok=false
report "first start: /health answers 200" $ok
[ "$ok" = true ] && info "cold start to /health at --memory $MEM: ${WAITED}s; memory.peak so far: $(mem_peak_mib) MiB"

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

ok=true
if app_logs | grep -qF "$PASS_1"; then ok=false; echo "  log echoes the admin password"; fi
if app_logs | grep -qF "$KEY_1"; then ok=false; echo "  log echoes the provider key"; fi
if app_logs | grep -qF "$KEY_CONTENT"; then ok=false; echo "  log echoes the session key"; fi
report "first start: log never contains the password, the provider key or the session key" $ok
info "upstream logs the admin email itself: $(app_logs | grep -c "$EMAIL_A") line(s) mention it"

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
printf '%s' "$HTTP_BODY" | jq -r '.data.content // ""' | grep -qF "zebra quantum pineapple" || { ok=false; echo "  extracted text does not contain the probe sentence"; }
app_logs | grep -qi 'embeddings generated' || { ok=false; echo "  no embedding step in the log"; }
if app_logs | grep -qi 'huggingface.co\|Downloading'; then ok=false; echo "  a download was attempted"; fi
report "first start: one-page PDF upload offline is extracted and embedded with the bundled model, no download attempted" $ok
info "memory.peak after cold start, signin and one PDF upload at --memory $MEM: $(mem_peak_mib) MiB"
sleep 10
info "memory.current after 10 s idle: $(mem_now_mib) MiB"

# ---------------------------------------------------------------------------
echo "==== Second start on the same storage"
stop_app
start_app -e DATA_DIR=/data -v "$D_MAIN:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
ok=true
wait_health || ok=false
[ "$ok" = true ] && info "warm restart to /health: ${WAITED}s"
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
report "forged X-Forwarded-* and Host headers confer nothing" $ok

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
  local phase="before the listener opened"
  if app_logs | grep -qF "$BOOTSTRAP_LINE"; then phase="after the admin was created"; elif listener_opened; then phase="after the listener opened"; fi
  keybefore=$(as_root "$d" 'cat /data/.dockhold/webui-secret-key 2>/dev/null || true')
  start_app -e DATA_DIR=/data -v "$d:/data" "${ADDR[@]}" "${SECRETS_A[@]}"
  wait_health || { ok=false; echo "  not healthy after the interrupted first start"; }
  tok=$(login "$EMAIL_A_LC" "$PASS_1")
  [ -n "$tok" ] || { ok=false; echo "  admin does not log in"; }
  one_admin "$tok" || { ok=false; echo "  users: $(users_json "$tok")"; }
  [[ "$(signup_code "stranger-$(rand_hex 3)@example.com")" =~ ^4 ]] || { ok=false; echo "  signup not refused"; }
  keyafter=$(as_root "$d" 'cat /data/.dockhold/webui-secret-key')
  if [ -n "$keybefore" ]; then
    [ "$keybefore" = "$keyafter" ] || { ok=false; echo "  the key written before the kill was replaced"; }
  fi
  report "interrupted first start ($label, $phase): healthy, one admin, signup refused, key kept" $ok
  stop_app
}
kill_1s() { sleep 1; }
kill_5s() { sleep 5; }
kill_after_bootstrap() {
  local i
  for i in $(seq 1 1200); do
    app_logs | grep -qF "$BOOTSTRAP_LINE" && return 0
    app_running || return 0
    sleep 0.1
  done
}
interrupted_case "KILL at 1 s" kill_1s
interrupted_case "KILL at 5 s" kill_5s
interrupted_case "KILL right after the bootstrap log line" kill_after_bootstrap

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
  info "at --memory 1g: cold start to /health ${WAITED}s; signin $([ -n "$TOK_1G" ] && echo ok || echo failed); PDF upload $UP1G; memory.peak $(mem_peak_mib) MiB; OOM-killed: $(app_oom); still running: $(app_running && echo yes || echo no)"
else
  info "at --memory 1g: did not become healthy within the limit; OOM-killed: $(app_oom); exit code: $(docker inspect -f '{{.State.ExitCode}}' "$APP" 2>/dev/null)"
fi
stop_app
MEM=2g

# ---------------------------------------------------------------------------
echo "==== Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
