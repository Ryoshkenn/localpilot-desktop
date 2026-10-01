#!/usr/bin/env bash
# One-time setup: build the native helper, register a local MLX model with pi,
# and install this package into pi.
#
#   scripts/setup.sh [model-dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${1:-$HOME/.lmstudio/models/lmstudio-community/Qwen3.5-4B-MLX-4bit}"
MODELS_JSON="$HOME/.pi/agent/models.json"

echo "Building helper..."
swift build -c release --package-path "$HERE/helper"
"$HERE/helper/.build/release/lpcu" permissions

if [ -d "$MODEL" ]; then
  mkdir -p "$(dirname "$MODELS_JSON")"
  node - "$MODELS_JSON" "$MODEL" <<'EOF'
const fs = require("fs");
const [file, model] = process.argv.slice(2);
const config = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
config.providers ??= {};
const provider = (config.providers["local-mlx"] ??= {
  baseUrl: "http://127.0.0.1:8090/v1",
  api: "openai-completions",
  apiKey: "local",
  models: [],
});
if (!provider.models.some((entry) => entry.id === model)) {
  provider.models.push({
    id: model,
    name: model.split("/").pop(),
    input: ["text", "image"],
    contextWindow: 32768,
    maxTokens: 4096,
  });
}
fs.writeFileSync(file, JSON.stringify(config, null, 2) + "\n");
console.log(`Registered ${model} as local-mlx/${model}`);
EOF
else
  echo "Model directory not found: $MODEL (skipping models.json)"
fi

if command -v pi >/dev/null; then
  pi install "$HERE"
else
  echo "pi is not installed: npm i -g @earendil-works/pi-coding-agent"
fi

cat <<EOF

Next:
  1. Grant your terminal Accessibility and Screen Recording access if the
     permissions above are false (System Settings > Privacy & Security).
  2. Start the model server:  $HERE/scripts/serve-model.sh "$MODEL"
  3. Run:                     pi --computer --model "local-mlx/$MODEL"
EOF
