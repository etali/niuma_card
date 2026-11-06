#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -eu
cd "$(dirname "$0")"
exec /bin/bash ./构建游戏.command --release "$@"
