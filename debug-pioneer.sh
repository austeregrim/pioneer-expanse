#!/usr/bin/env bash
# Launch Pioneer under GDB so any crash/segfault automatically prints a full C++ stack trace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="${SCRIPT_DIR}/build/pioneer"

if [[ ! -x "${BINARY}" ]]; then
	echo "Error: ${BINARY} not found. Build first with:"
	echo "  cmake --build build --target pioneer build-data -j 8"
	exit 1
fi

exec gdb -batch \
	-ex "set pagination off" \
	-ex "handle SIGPIPE nostop noprint pass" \
	-ex "run" \
	-ex "echo \n=== CRASH BACKTRACE ===\n" \
	-ex "bt 40" \
	-ex "echo \n=== LOCAL VARIABLES ===\n" \
	-ex "info locals" \
	-ex "quit" \
	--args "${BINARY}" "$@"
