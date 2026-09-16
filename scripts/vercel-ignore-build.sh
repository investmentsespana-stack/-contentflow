#!/usr/bin/env bash
set -euo pipefail

# Skip every non-main Git deployment. Branch previews are not required for the
# research/CI-heavy workflow and were consuming Hobby deployment storage.
if [[ "${VERCEL_GIT_COMMIT_REF:-}" != "main" ]]; then
  echo "Skipping Vercel build: non-main branch ${VERCEL_GIT_COMMIT_REF:-unknown}."
  exit 0
fi

base="${VERCEL_GIT_PREVIOUS_SHA:-}"
if [[ -z "$base" ]] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
  if git rev-parse HEAD^ >/dev/null 2>&1; then
    base="HEAD^"
  else
    echo "No reliable previous commit available; deploy fail-open for safety."
    exit 1
  fi
fi

mapfile -t changed < <(git diff --name-only "$base" HEAD)
if [[ ${#changed[@]} -eq 0 ]]; then
  echo "No changed files; skipping Vercel build."
  exit 0
fi

for file in "${changed[@]}"; do
  case "$file" in
    trading_super_strategy/*|.github/workflows/trading-*|docs/trading/*)
      ;;
    *)
      echo "Web-relevant change detected: $file; continue Vercel build."
      exit 1
      ;;
  esac
done

echo "Only Trading/Trading-CI files changed; skipping Vercel build."
exit 0
