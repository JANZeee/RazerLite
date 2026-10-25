#!/bin/bash
set -euo pipefail
exec /bin/bash "$(dirname "$0")/build-app.sh" debug scenarios
