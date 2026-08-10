#!/usr/bin/env bash
set -Eeuo pipefail

# Legacy entry point retained for old customer instructions.
# All installs are now verified by the Vast-locked V18 installer.
exec bash <(curl -fsSL https://raw.githubusercontent.com/fcktisaa/SEEDRAAI-installer-v2/main/SEEDRAAI-INSTALLER-XET-V18-VAST.sh) "$@"
