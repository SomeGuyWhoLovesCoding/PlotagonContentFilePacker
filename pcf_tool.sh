#!/bin/sh
# Wrapper — run with neko if available, otherwise print an error
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec neko "$SCRIPT_DIR/pcf_tool.n" "$@"
