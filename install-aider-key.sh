#!/usr/bin/env bash
# setup-aider-key.sh
# Securely stores GROQ_API_KEY for both interactive shells and systemd oneshot units.
set -euo pipefail

ENV_DIR="$HOME/.config/aider"
ENV_FILE="$ENV_DIR/env"
BASHRC="$HOME/.bashrc"

echo "This script will store your Groq API key for Aider."
echo "The key will be written only to:"
echo "  • $ENV_FILE          (mode 600 – used by systemd)"
echo "  • $BASHRC            (export line – used by interactive shells)"
echo

# Prompt securely (input is not echoed)
read -r -s -p "Paste your GROQ_API_KEY (input hidden): " GROQ_API_KEY
echo
if [[ -z "$GROQ_API_KEY" ]]; then
  echo "ERROR: No key entered. Aborting." >&2
  exit 1
fi

# 1. Create the environment file for systemd
mkdir -p "$ENV_DIR"
umask 077
printf 'GROQ_API_KEY=%s\n' "$GROQ_API_KEY" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "Wrote $ENV_FILE (mode 600)"

# 2. Ensure the interactive shell also has the key
#    Remove any previous GROQ_API_KEY line, then append a clean one.
if [[ -f "$BASHRC" ]]; then
  # Delete existing lines that set GROQ_API_KEY
  sed -i '/^export GROQ_API_KEY=/d' "$BASHRC"
fi
echo "export GROQ_API_KEY=\"$GROQ_API_KEY\"" >> "$BASHRC"
echo "Updated $BASHRC"

# 3. Make the key available in the *current* shell as well
export GROQ_API_KEY

echo
echo "Done."
echo "• New terminal sessions will automatically have GROQ_API_KEY."
echo "• Systemd oneshot units will load it from $ENV_FILE."
echo "• Current shell already has the variable exported."