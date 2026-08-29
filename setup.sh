#!/usr/bin/env bash
#
# Bootstrap a fresh clone of Execute (Executev3).
#
# Wires up the one gitignored secret file (.env.local) and installs deps so a
# freshly cloned folder can build for iOS / TestFlight from anywhere.
#
# Secrets are NEVER stored in git. This script links a canonical copy that
# lives OUTSIDE any clone:
#
#     ~/.execute.env.local
#
# One-time (from a folder that already works):
#     cp .env.local ~/.execute.env.local
#
# Then in every new clone just run:  ./setup.sh
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="${EXECUTE_ENV_FILE:-$HOME/.execute.env.local}"
TARGET="$REPO_DIR/.env.local"

cd "$REPO_DIR"

echo "==> Execute setup"
echo "    repo:      $REPO_DIR"
echo "    canonical: $CANONICAL"

# 1. Wire up secrets ---------------------------------------------------------
if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
  echo "==> .env.local already exists here (real file) — leaving it untouched."
elif [ -f "$CANONICAL" ]; then
  ln -sfn "$CANONICAL" "$TARGET"
  echo "==> Linked .env.local -> $CANONICAL"
else
  echo
  echo "!!! No canonical secrets file found at: $CANONICAL"
  echo "    Create it once from a folder that already works:"
  echo
  echo "        cp .env.local \"$CANONICAL\""
  echo
  echo "    (or set EXECUTE_ENV_FILE to point somewhere else), then re-run ./setup.sh"
  exit 1
fi

# 2. Sanity-check the required keys are present ------------------------------
REQUIRED_KEYS=(
  VITE_SUPABASE_URL
  VITE_SUPABASE_ANON_KEY
  VITE_SUPABASE_UPLOAD_BUCKET
  VITE_REVENUECAT_IOS_KEY
)
missing=0
for key in "${REQUIRED_KEYS[@]}"; do
  if ! grep -q "^${key}=" "$TARGET"; then
    echo "!!! Missing key in .env.local: $key"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "==> Fix the keys above in $CANONICAL, then re-run ./setup.sh"
  exit 1
fi
echo "==> All required keys present."

# 3. Install dependencies ----------------------------------------------------
echo "==> Installing npm dependencies..."
npm install

echo
echo "==> Done. Next steps:"
echo "      npm run ios:sync   # vite build + cap sync ios"
echo "      npm run ios:open   # open in Xcode, then Archive -> TestFlight"
