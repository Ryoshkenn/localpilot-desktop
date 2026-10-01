#!/usr/bin/env bash
# Serve a local MLX vision-language model with an OpenAI-compatible API for pi.
#
#   scripts/serve-model.sh [model-path] [port]
#
# Uses mlx-vlm (installed into ~/.localpilot/mlxenv on first run) with
# automatic prefix caching, so each agent step only prefills what changed.
set -euo pipefail

MODEL="${1:-$HOME/.lmstudio/models/lmstudio-community/Qwen3.5-4B-MLX-4bit}"
PORT="${2:-8090}"
VENV="${LOCALPILOT_VENV:-$HOME/.localpilot/mlxenv}"

if [ ! -x "$VENV/bin/python" ] || ! "$VENV/bin/python" -c "import mlx_vlm" 2>/dev/null; then
  echo "Installing mlx-vlm into $VENV ..."
  command -v uv >/dev/null || { echo "Install uv first: brew install uv"; exit 1; }
  uv venv -p 3.12 "$VENV"
  uv pip install -p "$VENV" mlx-vlm
fi

# Prefix caching. Qwen3.5 mixes linear and full attention layers, so the
# cache can only resume from checkpoints; take them often.
export APC_ENABLED=1
export APC_DISK_ENABLED="${APC_DISK_ENABLED:-0}"
export APC_CHECKPOINT_INTERVAL_TOKENS="${APC_CHECKPOINT_INTERVAL_TOKENS:-128}"
export APC_EXACT_CACHE_ENTRIES="${APC_EXACT_CACHE_ENTRIES:-32}"

exec "$VENV/bin/python" -m mlx_vlm.server --host 127.0.0.1 --port "$PORT" --model "$MODEL" ${MLX_VLM_EXTRA_ARGS:-}
