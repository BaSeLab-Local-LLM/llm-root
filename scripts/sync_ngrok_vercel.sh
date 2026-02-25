#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

FRONTEND_DIR="${FRONTEND_DIR:-${REPO_ROOT}/submodules/frontend}"
VERCEL_JSON="${VERCEL_JSON:-${FRONTEND_DIR}/vercel.json}"
NGROK_INSPECT_PORT="${NGROK_INSPECT_PORT:-4040}"
NGROK_API="${NGROK_API:-http://127.0.0.1:${NGROK_INSPECT_PORT}/api/tunnels}"
NGROK_CONTAINER_NAME="${NGROK_CONTAINER_NAME:-llm-ngrok}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
POLL_INTERVAL="${POLL_INTERVAL:-20}"
AUTO_PUSH="${AUTO_PUSH:-true}"
VERCEL_DEPLOY_HOOK_URL="${VERCEL_DEPLOY_HOOK_URL:-}"
LOCK_FILE="${LOCK_FILE:-/tmp/ngrok_vercel_sync.lock}"
GITHUB_USERNAME="${GITHUB_USERNAME:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

MODE="loop"
if [[ "${1:-}" == "--once" ]]; then
  MODE="once"
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

bool_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

get_ngrok_url_from_api() {
  local body url
  body="$(curl -fsS --max-time 5 "${NGROK_API}" 2>/dev/null || true)"
  if [[ -z "${body}" ]]; then
    return 1
  fi

  url="$(
    printf '%s' "${body}" \
      | tr -d '\n' \
      | sed -n 's/.*"public_url":"\(https:[^"]*\)".*/\1/p' \
      | head -n1
  )"

  [[ -n "${url}" ]] || return 1
  printf '%s\n' "${url%/}"
}

get_ngrok_url_from_logs() {
  local logs
  local url

  logs="$(docker logs --tail 120 "${NGROK_CONTAINER_NAME}" 2>&1 || true)"
  url="$(printf '%s' "${logs}" | sed -n 's/.*url=\(https:\/\/[^ ]*\).*/\1/p' | tail -n1)"

  [[ -n "${url}" ]] || return 1
  printf '%s\n' "${url%/}"
}

get_ngrok_url() {
  local url=""

  if url="$(get_ngrok_url_from_api)"; then
    printf '%s\n' "${url}"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    if url="$(get_ngrok_url_from_logs)"; then
      printf '%s\n' "${url}"
      return 0
    fi
  fi

  return 1
}

current_destination() {
  sed -n -E 's/.*"destination"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "${VERCEL_JSON}" | head -n1
}

update_vercel_json_destination() {
  local new_destination="$1"
  local escaped
  local tmp_file

  escaped="$(printf '%s' "${new_destination}" | sed 's/[\/&]/\\&/g')"
  tmp_file="$(mktemp)"

  sed -E "s#(\"destination\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")#\\1${escaped}\\2#" "${VERCEL_JSON}" > "${tmp_file}"
  mv "${tmp_file}" "${VERCEL_JSON}"
}

trigger_deploy_hook() {
  if [[ -z "${VERCEL_DEPLOY_HOOK_URL}" ]]; then
    return 0
  fi

  if curl -fsS -X POST "${VERCEL_DEPLOY_HOOK_URL}" >/dev/null; then
    log "vercel deploy hook triggered"
  else
    log "vercel deploy hook failed"
  fi
}

push_with_auth() {
  if [[ -n "${GITHUB_USERNAME}" && -n "${GITHUB_TOKEN}" ]]; then
    local askpass_file
    askpass_file="$(mktemp)"
    cat > "${askpass_file}" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' "${GITHUB_USERNAME}" ;;
  *Password*) printf '%s\n' "${GITHUB_TOKEN}" ;;
  *) printf '\n' ;;
esac
EOF
    chmod 700 "${askpass_file}"
    GIT_ASKPASS="${askpass_file}" GIT_TERMINAL_PROMPT=0 git push "${GIT_REMOTE}" "${GIT_BRANCH}" >/dev/null 2>&1
    local rc=$?
    rm -f "${askpass_file}"
    return "${rc}"
  fi

  git push "${GIT_REMOTE}" "${GIT_BRANCH}" >/dev/null 2>&1
}

sync_once() {
  local ngrok_url new_destination old_destination
  local committed=0
  local pushed=0

  if [[ ! -f "${VERCEL_JSON}" ]]; then
    log "vercel.json not found: ${VERCEL_JSON}"
    return 1
  fi

  ngrok_url="$(get_ngrok_url || true)"
  if [[ -z "${ngrok_url}" ]]; then
    log "ngrok url not found (api: ${NGROK_API})"
    return 1
  fi

  new_destination="${ngrok_url}/api/:path*"
  old_destination="$(current_destination || true)"

  if [[ "${new_destination}" == "${old_destination}" ]]; then
    log "no change (${new_destination})"
    return 0
  fi

  update_vercel_json_destination "${new_destination}"
  log "updated destination: ${old_destination} -> ${new_destination}"

  pushd "${FRONTEND_DIR}" >/dev/null

  if [[ "$(git rev-parse --abbrev-ref HEAD)" != "${GIT_BRANCH}" ]]; then
    log "current branch is not ${GIT_BRANCH}; skip git commit/push"
    popd >/dev/null
    return 0
  fi

  if ! git diff --quiet -- vercel.json; then
    git add vercel.json
    if git commit -m "chore: sync ngrok rewrite target to ${ngrok_url}" >/dev/null 2>&1; then
      committed=1
      log "committed vercel.json update"
    fi
  fi

  if (( committed == 1 )) && bool_true "${AUTO_PUSH}"; then
    if push_with_auth; then
      pushed=1
      log "pushed ${GIT_BRANCH} to ${GIT_REMOTE}"
    else
      log "git push failed (check credentials)"
    fi
  fi

  popd >/dev/null

  if (( committed == 1 )); then
    if bool_true "${AUTO_PUSH}"; then
      if (( pushed == 1 )); then
        trigger_deploy_hook
      fi
    else
      trigger_deploy_hook
    fi
  fi
}

# Best-effort lock: if lock file can't be opened in this runtime (e.g. hardened systemd),
# continue without lock instead of crash-looping.
if { exec 9>"${LOCK_FILE}"; } 2>/dev/null; then
  if ! flock -n 9; then
    log "another sync process is running"
    exit 0
  fi
else
  log "cannot open lock file (${LOCK_FILE}); continuing without lock"
fi

if [[ "${MODE}" == "once" ]]; then
  sync_once
  exit 0
fi

log "starting ngrok->vercel sync loop (interval=${POLL_INTERVAL}s)"
while true; do
  sync_once || true
  sleep "${POLL_INTERVAL}"
done
