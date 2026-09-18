#!/bin/sh
# Start script for Open WebUI on Dockhold.
#
# Dockhold hands this app a port (PORT, read by upstream's own start script)
# and, when App storage is turned on, a folder that survives restarts
# (DATA_DIR). The admin account and the model provider key come from
# Dockhold's Secrets as WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD and
# OPENAI_API_KEY. This script checks those, puts every file Open WebUI
# writes on App storage, guards the session key, and then hands over to
# upstream's start.sh. It reads DATA_DIR, DATABASE_URL, DOCKHOLD_APP_URL,
# the three secrets, and the optional overrides WEBUI_SECRET_KEY,
# WEBUI_URL, ENABLE_OLLAMA_API, OPENAI_API_BASE_URL, JWT_EXPIRES_IN and
# ENABLE_SIGNUP. It never prints a secret value.
#
# Every check below fails with one line and exit code 1. Dockhold shows that
# line on the app page, so the line is the whole error message.
set -eu

TEMPLATE_VERSION="0.11.3"

# 1. App storage.
#
# Open WebUI keeps everything (its database, uploads, the document index,
# the session key) in one folder. Without App storage that folder would be
# gone after the next restart, so the app refuses to start instead of
# starting empty. There is no fallback to a folder inside the image, on
# purpose: it would look like it works and lose every chat on the first
# restart.
storage_missing() {
  echo "This app keeps its data on App storage. Turn on App storage in the Size tab and redeploy." >&2
  exit 1
}
[ -n "${DATA_DIR:-}" ] || storage_missing
case "$DATA_DIR" in /*) ;; *) storage_missing ;; esac
[ -d "$DATA_DIR" ] || storage_missing
[ -w "$DATA_DIR" ] || storage_missing
# Permission bits can say "writable" on a folder that is mounted read-only.
# Creating and removing a file is the only check that cannot be fooled.
probe="$DATA_DIR/.dockhold-write-check.$$"
( : > "$probe" ) 2>/dev/null || storage_missing
rm -f "$probe"

# 2. The managed database is not supported by this version of the template.
#
# Open WebUI would accept DATABASE_URL and move its data there, and the
# data already on App storage would silently stop being used. Refusing is
# better than a quiet move. Support for the managed database is a later,
# tested change.
if [ -n "${DATABASE_URL:-}" ]; then
  echo "This template keeps Open WebUI's data on App storage and does not use the managed database yet. Turn the managed database off for this app and redeploy." >&2
  exit 1
fi

# 3. Secrets.
#
# All three must be present and non-empty, and the admin values must be
# ones Open WebUI will accept. The check runs before anything listens: Open
# WebUI creates the admin account from these values on its first start, and
# when that fails it logs the failure and starts anyway, with no admin and
# with the first person to reach the URL able to sign up as the admin
# instead. So the values are checked here, with the same limits upstream
# applies. The values themselves are never printed.
missing=""
[ -n "${WEBUI_ADMIN_EMAIL:-}" ] || missing="WEBUI_ADMIN_EMAIL"
[ -n "${WEBUI_ADMIN_PASSWORD:-}" ] || missing="${missing:+$missing, }WEBUI_ADMIN_PASSWORD"
[ -n "${OPENAI_API_KEY:-}" ] || missing="${missing:+$missing, }OPENAI_API_KEY"
if [ -n "$missing" ]; then
  # "A, B, C" reads as "A, B and C".
  case "$missing" in
    *,*) missing="$(printf '%s' "$missing" | sed 's/, \([^,]*\)$/ and \1/')" ;;
  esac
  echo "$missing is missing or empty. Add WEBUI_ADMIN_EMAIL, WEBUI_ADMIN_PASSWORD and OPENAI_API_KEY as secrets on this app's Variables tab and restart." >&2
  exit 1
fi
case "$WEBUI_ADMIN_EMAIL" in
  *@*) ;;
  *)
    echo "WEBUI_ADMIN_EMAIL is not an email address (it has no @). Fix the secret under Settings > Secrets and restart." >&2
    exit 1
    ;;
esac
# Upstream stores the password with bcrypt, which refuses anything over 72
# bytes, and sets no minimum at all. 72 is upstream's limit; 8 is this
# template's floor, because an admin account with a shorter password is
# the front door to every chat on the app.
pw_bytes=$(printf '%s' "$WEBUI_ADMIN_PASSWORD" | wc -c | tr -d ' ')
if [ "$pw_bytes" -lt 8 ] || [ "$pw_bytes" -gt 72 ]; then
  echo "WEBUI_ADMIN_PASSWORD must be 8 to 72 characters long. Fix the secret under Settings > Secrets and restart." >&2
  exit 1
fi

# 4. The template's own folder on App storage.
#
# Everything this script creates lives under .dockhold so Open WebUI's own
# layout stays untouched. Mode 0700: the session key lives here.
DH="$DATA_DIR/.dockhold"
mkdir -p "$DH"
# Five digits: with four, coreutils chmod keeps a setgid bit the folder
# inherited from App storage.
chmod 00700 "$DH"

# 5. The session key.
#
# Open WebUI signs every login with one secret key. Upstream's start.sh
# reads it from the file named by WEBUI_SECRET_KEY_FILE, or from the
# WEBUI_SECRET_KEY variable when that is set, and generates a file when
# neither exists. Losing the key signs every user out and makes tokens
# stored for single sign-on unreadable, so the file lives on App storage
# and this script never overwrites or regenerates one that was there
# before.
#
# The order matters for an interrupted first start. The key is created
# first and the established-install marker (step 6) only after it, so a
# kill at any point leaves either nothing (the next start is a first
# start again) or a key file and a marker that agree. There is no state in
# which the marker says "established" while the key was never written.
#
# A bound WEBUI_SECRET_KEY wins over the file, as it does upstream. That is
# the recovery path for a lost or damaged file, so none of the file checks
# run while it is bound.
KEY_FILE="$DH/webui-secret-key"
export WEBUI_SECRET_KEY_FILE="$KEY_FILE"
key_damaged() {
  echo "The app's session key file on App storage is damaged. Bind WEBUI_SECRET_KEY to the previous key or restore the file from your backup; the file is never overwritten." >&2
  exit 1
}
if [ -z "${WEBUI_SECRET_KEY:-}" ]; then
  if [ -e "$KEY_FILE" ]; then
    # Upstream writes 24 random bytes as one line of base64: 32 characters.
    # Anything shorter, empty, or not base64 is a truncated or altered file,
    # and a key that is wrong in any way is a key that signs nobody in.
    [ -f "$KEY_FILE" ] || key_damaged
    [ "$(wc -l < "$KEY_FILE" | tr -d ' ')" -le 1 ] || key_damaged
    head -n 1 "$KEY_FILE" | grep -Eqx '[A-Za-z0-9+/]{32,}={0,2}' || key_damaged
  elif [ -e "$DH/template" ]; then
    echo "The app's session key is missing from App storage. Restore it from your backup or bind WEBUI_SECRET_KEY to the previous value." >&2
    exit 1
  else
    # First start: create the key the way upstream would, but atomically,
    # so a kill during the write cannot leave a half-written file behind.
    rm -f "$DH"/webui-secret-key.tmp.*
    tmp="$KEY_FILE.tmp.$$"
    (umask 077 && head -c 24 /dev/urandom | base64 > "$tmp")
    head -n 1 "$tmp" | grep -Eqx '[A-Za-z0-9+/]{32,}={0,2}' || { rm -f "$tmp"; key_damaged; }
    mv -f "$tmp" "$KEY_FILE"
  fi
fi

# 6. Established-install marker.
#
# Written only after every check above passed and the session key exists,
# so it is on a storage folder that has actually run this template. Its
# presence means "an existing installation": from now on a missing key
# file is an error (step 5), never a silent new key. Nothing in this script
# ever wipes or re-seeds a folder, with or without the marker.
printf 'open-webui-starter %s\n' "$TEMPLATE_VERSION" > "$DH/template"

# 7. Where Open WebUI writes, and the settings it starts from.
#
# HOME: upstream runs as root with HOME=/root, which user 1001 cannot write.
# Anything a library keeps under the home folder lands on App storage
# instead.
export HOME="$DH/home"
mkdir -p "$HOME"
chmod 00700 "$HOME"
export DATA_DIR

# The settings below are read on the first start only. Open WebUI stores
# them in its database and from then on the admin panel owns them: a later
# change to one of these variables does nothing on an existing
# installation (the README has the table). So:
#   WEBUI_URL         the app's public address, for links in emails and
#                     single sign-on; Dockhold's address unless overridden
#   ENABLE_OLLAMA_API off: this template runs no local chat models
#   OPENAI_API_BASE_URL  OpenAI unless another OpenAI-compatible provider
#                     is named (OpenRouter, for example)
#   JWT_EXPIRES_IN    a login lasts seven days; without a session store a
#                     password change cannot end a session sooner
#   ENABLE_SIGNUP     closed. Open WebUI closes it itself once the admin
#                     exists; seeding it closed as well means the stored
#                     setting starts closed no matter what. It does not,
#                     on its own, stop a first user from signing up while
#                     no account exists at all: upstream always lets the
#                     first account in. That is why step 3 refuses every
#                     value the admin bootstrap would fail on.
export WEBUI_URL="${WEBUI_URL:-${DOCKHOLD_APP_URL:-}}"
export ENABLE_OLLAMA_API="${ENABLE_OLLAMA_API:-false}"
export OPENAI_API_BASE_URL="${OPENAI_API_BASE_URL:-https://api.openai.com/v1}"
export JWT_EXPIRES_IN="${JWT_EXPIRES_IN:-7d}"
export ENABLE_SIGNUP="${ENABLE_SIGNUP:-false}"

# 8. Hand over to Open WebUI.
#
# Upstream's start.sh reads PORT and the key file, then execs the server,
# so the server is the main process and the stop signal from the platform
# reaches it directly.
cd /app/backend
exec bash start.sh
