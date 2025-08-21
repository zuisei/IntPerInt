#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 -m venv .venv
source .venv/bin/activate

# Offline install from wheels directory
pip install --no-index --find-links=./wheels -r requirements.txt

echo "Installed offline into .venv"
