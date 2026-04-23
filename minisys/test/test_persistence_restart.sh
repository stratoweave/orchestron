#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTON_BIN="${ACTON:-acton}"
ACTON_BUILD_ARGS="${ACTON_BUILD_ARGS:-}"
CURL_BIN="${CURL:-curl}"
PORT="${PORT:-$((18080 + RANDOM % 1000))}"
DB_PATH="$ROOT_DIR/minisys/test/persistence-restart.db"
BIN_FILE="$ROOT_DIR/minisys/out/bin/mini"
PID=""
CONFIG_JSON='{"netinfra:netinfra":{"global-settings":{"asn":123},"router":[{"name":"rtr1","id":1,"type":"ietf","mock":true}]}}'

cleanup() {
    if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

wait_for_http() {
    local url="http://127.0.0.1:${PORT}/layer/0"
    for _ in $(seq 1 100); do
        if "$CURL_BIN" --connect-timeout 1 --max-time 2 -fsS -H "Accept: application/yang-data+json" "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    fail "mini did not start listening on port ${PORT}"
}

start_mini() {
    (
        cd "$ROOT_DIR"
        exec "$BIN_FILE" --db "$DB_PATH" --http-port "$PORT"
    ) >/dev/null 2>&1 &
    PID=$!
    wait_for_http
}

stop_mini() {
    if [[ -n "${PID:-}" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        for _ in $(seq 1 20); do
            if ! kill -0 "$PID" 2>/dev/null; then
                wait "$PID" || true
                PID=""
                return 0
            fi
            sleep 0.1
        done
        kill -9 "$PID" 2>/dev/null || true
        wait "$PID" || true
    fi
    PID=""
}

layer0_json() {
    "$CURL_BIN" --connect-timeout 1 --max-time 5 -fsS -H "Accept: application/yang-data+json" "http://127.0.0.1:${PORT}/layer/0"
}

compact_json() {
    printf '%s' "$1" | tr -d '[:space:]'
}

trap cleanup EXIT

cd "$ROOT_DIR"
rm -rf "$DB_PATH"
if command -v "$ACTON_BIN" >/dev/null 2>&1; then
    "$ACTON_BIN" build $ACTON_BUILD_ARGS minisys/src/mini.act
elif [[ ! -x "$BIN_FILE" ]]; then
    fail "acton not found on PATH and ${BIN_FILE} is missing; set ACTON=/path/to/acton"
fi

start_mini
"$CURL_BIN" -fsS -X PUT \
    --connect-timeout 1 \
    --max-time 5 \
    -H "Content-Type: application/yang-data+json" \
    --data-binary "$CONFIG_JSON" \
    "http://127.0.0.1:${PORT}/restconf/data" >/dev/null

before_restart_json="$(layer0_json)"
[[ "$(compact_json "$before_restart_json")" == *'"name":"rtr1"'* ]] || fail "layer 0 JSON did not contain expected router config before restart"

stop_mini
start_mini

after_restart_json="$(layer0_json)"
[[ "$(compact_json "$after_restart_json")" == *'"name":"rtr1"'* ]] || fail "layer 0 JSON did not contain expected router config after restart"

if [[ "$(compact_json "$before_restart_json")" != "$(compact_json "$after_restart_json")" ]]; then
    diff -u <(printf '%s\n' "$before_restart_json") <(printf '%s\n' "$after_restart_json") || true
    fail "layer 0 JSON config changed across restart"
fi

echo "Persistence restart test passed on port ${PORT}"
