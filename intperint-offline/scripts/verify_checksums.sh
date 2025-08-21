#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f checksums/models.sha256 ]]; then
  echo "checksums/models.sha256 not found. Skipping."
  exit 0
fi

# Verify checksums under models/
( cd models && shasum -a 256 -c ../checksums/models.sha256 )
