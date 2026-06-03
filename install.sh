#!/usr/bin/env bash
# Caffeinate Timer installer — macOS / Linux
# Usage: curl -fsSL https://raw.githubusercontent.com/igarinpiano/caffeinate-timer/main/install.sh | bash
set -euo pipefail

REPO="igarinpiano/caffeinate-timer"
INSTALL_DIR="${HOME}/.local/bin"
BASE_URL="https://github.com/${REPO}/releases/latest/download"

# ── OS detection ───────────────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
  Darwin) FILE="caffeinate-timer.command" ;;
  Linux)  FILE="caffeinate-timer-universal.sh" ;;
  *)
    printf 'Unsupported OS: %s\n' "$OS" >&2
    exit 1
    ;;
esac

# ── SHA-256 command detection ──────────────────────────────────────────────
if command -v sha256sum &>/dev/null; then
  _sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum &>/dev/null; then
  _sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  printf 'Error: sha256sum or shasum not found\n' >&2
  exit 1
fi

# ── Download to a TOCTOU-safe temp directory ───────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

printf 'Downloading %s...\n' "$FILE"
curl --proto '=https' --tlsv1.2 --max-redirs 5 -fsSL \
  "${BASE_URL}/${FILE}" -o "${TMP_DIR}/${FILE}"
curl --proto '=https' --tlsv1.2 --max-redirs 5 -fsSL \
  "${BASE_URL}/checksums.txt" -o "${TMP_DIR}/checksums.txt"

# ── Checksum verification ──────────────────────────────────────────────────
printf 'Verifying checksum...\n'
EXPECTED="$(awk -v f="$FILE" '{gsub(/^\*/, "", $2); if ($2 == f) print $1}' \
  "${TMP_DIR}/checksums.txt")"
if [ -z "$EXPECTED" ]; then
  printf 'Error: checksum for %s not found in checksums.txt\n' "$FILE" >&2
  exit 1
fi
ACTUAL="$(_sha256 "${TMP_DIR}/${FILE}")"
if [ "$EXPECTED" != "$ACTUAL" ]; then
  printf 'Error: checksum mismatch\n  expected: %s\n  actual:   %s\n' \
    "$EXPECTED" "$ACTUAL" >&2
  exit 1
fi
printf 'Checksum OK.\n'

# ── Shebang validation ─────────────────────────────────────────────────────
SHEBANG="$(head -1 "${TMP_DIR}/${FILE}")"
if [[ "$SHEBANG" != '#!/'* ]]; then
  printf 'Error: downloaded file does not look like a shell script\n' >&2
  exit 1
fi

# ── Install ────────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
mv "${TMP_DIR}/${FILE}" "${INSTALL_DIR}/caffeinate-timer"
chmod +x "${INSTALL_DIR}/caffeinate-timer"

printf '\n✅ Installed to %s/caffeinate-timer\n' "$INSTALL_DIR"

# ── PATH check ─────────────────────────────────────────────────────────────
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  printf '\nNote: %s is not in your PATH.\n' "$INSTALL_DIR"
  case "$(basename "${SHELL:-bash}")" in
    zsh)  RC_FILE="~/.zshrc" ;;
    bash) RC_FILE="~/.bashrc" ;;
    *)    RC_FILE="your shell config file" ;;
  esac
  printf 'Add this line to %s:\n' "$RC_FILE"
  printf '  export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
  printf 'Then reload your shell or run:\n'
  printf '  source %s\n' "$RC_FILE"
fi
