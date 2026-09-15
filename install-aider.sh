#!/usr/bin/env bash
#
# install-aider.sh
#
# Purpose:
#   Installs aider-chat into a dedicated Python virtualenv and installs a
#   thin wrapper (`aider-run`) that supports two modes of operation:
#
#     1. Non-interactive / background (default):
#        Invoked programmatically or by a scheduler with --message-file.
#        Aider executes the supplied task prompt, applies edits, commits
#        (if configured), exits cleanly, and performs no further work until
#        the next explicit invocation.  Suitable for cron, systemd timers,
#        or any external orchestrator.
#
#     2. Interactive (TTY or explicit flag):
#        When a controlling terminal is detected or --interactive is passed,
#        the classic interactive Aider chat session is started.
#
#   A systemd --user *oneshot* unit template is also installed so that
#   individual tasks can be launched cleanly via systemd-run or timers
#   without leaving a long-running process.
#
#   The API key is NEVER stored by this script.  It must be supplied via the
#   environment variable GROQ_API_KEY (interactive shells) or via an
#   EnvironmentFile (systemd).  See the companion setup-aider-key.sh helper.
#
# Usage:
#   ./install-aider.sh [REPOSITORY_PATH]
#
#   REPOSITORY_PATH  Optional. Absolute or relative path to the git repository
#                    Aider should operate in. Defaults to the current working
#                    directory ($PWD).
#
# Examples:
#   ./install-aider.sh
#   ./install-aider.sh \~/projects/my-app
#   ./install-aider.sh /srv/repos/backend
#
# After installation typical non-interactive usage:
#   aider-run --message-file /path/to/task.txt
#   # or via systemd:
#   systemctl --user start "aider-task@$(systemd-escape --path /path/to/task.txt).service"
#
# Requirements:
#   - Debian/Ubuntu-based system with sudo privileges
#   - systemd with a user session (systemctl --user must work)
#
# Exit codes:
#   0  Success
#   1  Invalid arguments or environment
#   2  Dependency installation failed
#   3  Virtualenv / pip setup failed
#   4  Wrapper or systemd unit creation failed
#
set -euo pipefail

# === CONFIG ===
AIDER_ENV="$HOME/.aider-env"
AIDER_BIN="$AIDER_ENV/bin/aider"
WRAPPER_BIN="$HOME/.local/bin/aider-run"
SERVICE_NAME="aider-task@.service"
DEFAULT_REPO="$PWD"

# Default model: Groq Llama 3.3 70B (free-tier friendly, fast, reliable for testing).
# Requires GROQ_API_KEY to be set in the environment (never hard-coded here).
# See https://aider.chat/docs/llms/groq.html for guidance.
DEFAULT_MODEL="groq/llama-3.3-70b-versatile"

# === HELPERS ===
log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

die() {
  local code="$1"; shift
  err "$*"
  exit "$code"
}

on_error() {
  local exit_code=$?
  err "Installation failed (exit code $exit_code). See messages above."
  exit "$exit_code"
}
trap on_error ERR

require_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    die 1 "'sudo' is required but not installed. Please install it or run as root."
  fi
  if ! sudo -n true 2>/dev/null; then
    log "This script needs sudo privileges to install system packages."
    if ! sudo -v; then
      die 1 "Unable to obtain sudo privileges."
    fi
  fi
}

require_systemd_user() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die 1 "'systemctl' not found. This script requires systemd."
  fi
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    die 1 "systemd --user session is not available. Ensure you are logged into a user session (loginctl enable-linger may help)."
  fi
}

resolve_repo() {
  local input="${1:-$DEFAULT_REPO}"
  if [ ! -d "$input" ]; then
    die 1 "Repository path does not exist: $input"
  fi
  # Absolute, canonical path
  REPO_DIR="$(cd "$input" && pwd -P)"
  if [ ! -d "$REPO_DIR/.git" ]; then
    warn "$REPO_DIR does not appear to be a git repository (no .git directory)."
  fi
  log "Target repository: $REPO_DIR"
}

# === FUNCTIONS ===
install_dependencies() {
  log "Installing system dependencies..."
  if ! sudo apt-get update -y; then
    die 2 "apt-get update failed."
  fi
  if ! sudo apt-get install -y python3 python3-venv python3-pip git; then
    die 2 "Failed to install system packages."
  fi
}

setup_virtualenv() {
  log "Setting up Python virtualenv at $AIDER_ENV..."
  if [ ! -d "$AIDER_ENV" ]; then
    if ! python3 -m venv "$AIDER_ENV"; then
      die 3 "Failed to create virtualenv at $AIDER_ENV."
    fi
  else
    log "Reusing existing virtualenv."
  fi

  # shellcheck disable=SC1091
  if ! source "$AIDER_ENV/bin/activate"; then
    die 3 "Failed to activate virtualenv."
  fi

  if ! pip install --upgrade pip; then
    die 3 "Failed to upgrade pip."
  fi
  if ! pip install aider-chat; then
    die 3 "Failed to install aider-chat."
  fi

  if [ ! -x "$AIDER_BIN" ]; then
    die 3 "Aider binary not found at $AIDER_BIN after installation."
  fi
}

create_wrapper() {
  log "Installing wrapper script at $WRAPPER_BIN..."
  local bin_dir
  bin_dir="$(dirname "$WRAPPER_BIN")"
  if ! mkdir -p "$bin_dir"; then
    die 4 "Failed to create directory: $bin_dir"
  fi

  # Ensure \~/.local/bin is on PATH for future sessions (best-effort)
  if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
    warn "$bin_dir is not currently on PATH. Add it to your shell profile if needed."
  fi

  cat > "$WRAPPER_BIN" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# aider-run — thin wrapper around aider that defaults to non-interactive
# task execution via --message-file and only enters interactive mode when
# a TTY is present or --interactive is supplied.
#
# The API key is NEVER hard-coded.  GROQ_API_KEY must already be present
# in the environment (export it, put it in \~/.bashrc, or load it via
# systemd EnvironmentFile).
set -euo pipefail

AIDER_ENV="${HOME}/.aider-env"
AIDER_BIN="${AIDER_ENV}/bin/aider"
DEFAULT_MODEL="groq/llama-3.3-70b-versatile"
REPO_DIR="__REPO_DIR_PLACEHOLDER__"

if [[ -z "${GROQ_API_KEY:-}" ]]; then
  echo "ERROR: GROQ_API_KEY is not set in the environment." >&2
  echo "       Export it, add it to \~/.bashrc, or use the setup-aider-key.sh helper." >&2
  exit 1
fi
export GROQ_API_KEY

if [ ! -x "$AIDER_BIN" ]; then
  echo "ERROR: aider binary not found at $AIDER_BIN" >&2
  exit 1
fi

# Parse a few wrapper-specific flags; pass everything else through.
INTERACTIVE=0
MESSAGE_FILE=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive|-i)
      INTERACTIVE=1
      shift
      ;;
    --message-file|-f)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --message-file requires a path argument" >&2
        exit 1
      fi
      MESSAGE_FILE="$2"
      shift 2
      ;;
    --model)
      EXTRA_ARGS+=("$1" "$2")
      shift 2
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

# Decide mode
if [[ $INTERACTIVE -eq 1 ]] || { [[ -t 0 ]] && [[ -z "$MESSAGE_FILE" ]]; }; then
  # Interactive session
  exec "$AIDER_BIN" \
    --model "${DEFAULT_MODEL}" \
    --yes-always \
    "${EXTRA_ARGS[@]}"
else
  # Non-interactive / background task mode (default)
  if [[ -z "$MESSAGE_FILE" ]]; then
    echo "ERROR: Non-interactive mode requires --message-file <path>" >&2
    echo "       Or pass --interactive / run from a TTY for chat mode." >&2
    exit 1
  fi
  if [[ ! -f "$MESSAGE_FILE" ]]; then
    echo "ERROR: Message file not found: $MESSAGE_FILE" >&2
    exit 1
  fi

  # Execute the single task and exit.  Aider performs its own cleanup.
  exec "$AIDER_BIN" \
    --model "${DEFAULT_MODEL}" \
    --message-file "$MESSAGE_FILE" \
    --yes-always \
    --no-pretty \
    "${EXTRA_ARGS[@]}"
fi
WRAPPER_EOF

  # Inject the concrete repository path (absolute, already resolved)
  sed -i "s|__REPO_DIR_PLACEHOLDER__|${REPO_DIR}|g" "$WRAPPER_BIN"

  chmod 755 "$WRAPPER_BIN"
  log "Wrapper installed: $WRAPPER_BIN"
}

create_systemd_oneshot() {
  log "Creating systemd user oneshot template '$SERVICE_NAME'..."
  local service_dir="$HOME/.config/systemd/user"
  local service_file="$service_dir/$SERVICE_NAME"

  if ! mkdir -p "$service_dir"; then
    die 4 "Failed to create directory: $service_dir"
  fi

  # Template unit: aider-task@/absolute/path/to/message.txt.service
  # The instance name after @ is the message-file path.
  # API key is loaded from a user-controlled EnvironmentFile (never embedded).
  cat > "$service_file" <<EOF
[Unit]
Description=Aider one-shot task (%i)
After=network-online.target
Documentation=man:aider(1)

[Service]
Type=oneshot
WorkingDirectory=$REPO_DIR
Environment=PATH=$AIDER_ENV/bin:/usr/bin:/bin
# Load GROQ_API_KEY from a file the user creates (mode 600 recommended).
# Example:  echo 'GROQ_API_KEY=gsk_...' > \~/.config/aider/env && chmod 600 \~/.config/aider/env
EnvironmentFile=-%h/.config/aider/env
ExecStart=$WRAPPER_BIN --message-file %i
RemainAfterExit=no

[Install]
WantedBy=default.target
EOF

  if ! systemctl --user daemon-reload; then
    die 4 "systemctl daemon-reload failed."
  fi

  # Do NOT enable or start anything permanently.
  log "Oneshot template installed.  It is NOT enabled as a permanent service."
  log "Example invocation:"
  log "  systemctl --user start 'aider-task@$(systemd-escape --path /path/to/task.txt).service'"
}

# === MAIN ===
main() {
  if [ "\( {1:-}" = "-h" ] || [ " \){1:-}" = "--help" ]; then
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
  fi

  if [ "$#" -gt 1 ]; then
    die 1 "Too many arguments. Usage: $0 [REPOSITORY_PATH]"
  fi

  require_sudo
  require_systemd_user
  resolve_repo "${1:-}"

  install_dependencies
  setup_virtualenv
  create_wrapper
  create_systemd_oneshot

  echo
  log "Aider AI installed successfully."
  log "Repository:          $REPO_DIR"
  log "Wrapper:             $WRAPPER_BIN"
  log "Default model:       $DEFAULT_MODEL"
  log "Systemd template:    $SERVICE_NAME  (oneshot – not permanently enabled)"
  log ""
  log "IMPORTANT: No API key is stored by this installer."
  log "  • For interactive use:  export GROQ_API_KEY=...  (or use setup-aider-key.sh)"
  log "  • For systemd:          place the key in \~/.config/aider/env (mode 600)"
  log ""
  log "Non-interactive usage (default):"
  log "  $WRAPPER_BIN --message-file /path/to/task-prompt.txt"
  log ""
  log "Interactive usage:"
  log "  $WRAPPER_BIN --interactive"
  log "  # or simply run from a TTY without --message-file"
}

main "$@"
