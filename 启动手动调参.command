#!/bin/bash
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${PYTHON:-/usr/bin/python3}
PORT=${PORT:-29861}
exec "$PYTHON" "$ROOT/tools/manual_balance.py" --port "$PORT" --open
