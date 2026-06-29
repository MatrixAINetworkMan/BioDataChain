#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# stop-all.sh - Gracefully stop all L2 chain services
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$ROOT_DIR/data"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[STOP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Stop in reverse order of startup
for svc in bridge-op-node bridge-op-geth op-proposer op-batcher op-node op-geth; do
    PID_FILE="$DATA_DIR/${svc}.pid"
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            log "Stopping $svc (PID $PID)..."
            kill "$PID"
            # Wait up to 30 seconds for graceful shutdown
            for i in $(seq 1 30); do
                if ! kill -0 "$PID" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            if kill -0 "$PID" 2>/dev/null; then
                warn "$svc did not stop gracefully, sending SIGKILL..."
                kill -9 "$PID" 2>/dev/null || true
            fi
            log "$svc stopped."
        else
            warn "$svc: already stopped (stale PID $PID)"
        fi
        rm -f "$PID_FILE"
    fi
done

log "All services stopped."
