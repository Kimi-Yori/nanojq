#!/bin/bash
# nanojq benchmark — hyperfine comparison vs jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SCRIPT_DIR/nanojq" ]; then
    NJQ="$SCRIPT_DIR/nanojq"
elif [ -x "$SCRIPT_DIR/nanojq-dynamic" ]; then
    NJQ="$SCRIPT_DIR/nanojq-dynamic"
else
    NJQ=""
fi
JQ="$(command -v jq || true)"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

if [ -z "$NJQ" ] || [ ! -x "$NJQ" ]; then
    echo "error: no nanojq binary found. run 'make' or 'make dynamic' first." >&2
    exit 1
fi

if [ -z "$JQ" ]; then
    echo "error: jq not found. install with: sudo apt install jq" >&2
    exit 1
fi

if ! command -v hyperfine &>/dev/null; then
    echo "error: hyperfine not found. install with: sudo apt install hyperfine" >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "error: python3 not found (needed for test data generation)" >&2
    exit 1
fi

echo "=== nanojq benchmark ==="
echo ""
echo "nanojq: $($NJQ --version)"
echo "jq:     $(jq --version)"
echo "hyperfine: $(hyperfine --version)"
echo ""

# --- generate test data ---

# 1KB — small API response
cat > "$TMPDIR/1kb.json" << 'EOF'
{"id":12345,"name":"alice","role":"engineer","skills":["debugging","refactoring","TDD"],"metadata":{"version":"0.1.0","created":"2026-03-06","tags":["cli","json","lightweight"],"nested":{"deep":{"value":"found_it"}}},"numbers":[1,2,3,4,5,6,7,8,9,10],"description":"An ultra-lightweight JSON selector CLI for LLM agent pipelines. Designed to be small, fast, and dependency-free. Built with jsmn tokenizer."}
EOF

# 10KB — medium config
python3 -c "
import json
data = {
    'providers': {
        f'provider_{i}': {
            'name': f'Provider {i}',
            'api_key': f'sk-{i:032x}',
            'enabled': i % 2 == 0,
            'models': [f'model-{j}' for j in range(5)],
            'config': {'timeout': 30, 'retries': 3, 'base_url': f'https://api{i}.example.com'}
        } for i in range(20)
    },
    'version': '2.0.0',
    'settings': {'debug': False, 'log_level': 'info'}
}
print(json.dumps(data))
" > "$TMPDIR/10kb.json"

# 100KB — large payload
python3 -c "
import json
data = {
    'results': [
        {
            'id': i,
            'name': f'Item {i}',
            'description': 'x' * 100,
            'tags': [f'tag{j}' for j in range(10)],
            'metadata': {
                'created': '2026-01-01',
                'score': i * 0.1,
                'nested': {'a': {'b': {'c': f'value_{i}'}}}
            }
        } for i in range(200)
    ],
    'total': 200,
    'page': 1
}
print(json.dumps(data))
" > "$TMPDIR/100kb.json"

# 1MB — huge JSON
python3 -c "
import json
data = {
    'records': [
        {
            'id': i,
            'payload': 'A' * 200,
            'values': list(range(20)),
            'meta': {'key': f'k{i}', 'val': f'v{i}'}
        } for i in range(2000)
    ],
    'count': 2000
}
print(json.dumps(data))
" > "$TMPDIR/1mb.json"

for f in 1kb 10kb 100kb 1mb; do
    actual=$(wc -c < "$TMPDIR/${f}.json")
    echo "  ${f}.json: ${actual} bytes"
done
echo ""

# --- benchmarks ---

echo "--- 1. Simple key extraction (1KB) ---"
hyperfine --warmup 50 --min-runs 200 --shell=none \
    "$NJQ .name $TMPDIR/1kb.json" \
    "$JQ -r .name $TMPDIR/1kb.json" \
    --export-markdown "$TMPDIR/bench_1kb.md" 2>&1
echo ""

echo "--- 2. Nested key (10KB) ---"
hyperfine --warmup 50 --min-runs 200 --shell=none \
    "$NJQ .providers.provider_10.api_key $TMPDIR/10kb.json" \
    "$JQ -r .providers.provider_10.api_key $TMPDIR/10kb.json" \
    --export-markdown "$TMPDIR/bench_10kb.md" 2>&1
echo ""

echo "--- 3. Array + nested (100KB) ---"
hyperfine --warmup 20 --min-runs 100 --shell=none \
    "$NJQ .results[99].metadata.nested.a.b.c $TMPDIR/100kb.json" \
    "$JQ -r .results[99].metadata.nested.a.b.c $TMPDIR/100kb.json" \
    --export-markdown "$TMPDIR/bench_100kb.md" 2>&1
echo ""

echo "--- 4. Large file top-level key (1MB) ---"
hyperfine --warmup 10 --min-runs 50 --shell=none \
    "$NJQ .count $TMPDIR/1mb.json" \
    "$JQ -r .count $TMPDIR/1mb.json" \
    --export-markdown "$TMPDIR/bench_1mb.md" 2>&1
echo ""

echo "--- 5. Startup overhead (stdin, tiny input; includes shell+echo cost) ---"
hyperfine --warmup 50 --min-runs 500 \
    "echo '{\"x\":1}' | $NJQ '.x'" \
    "echo '{\"x\":1}' | $JQ -r '.x'" \
    --export-markdown "$TMPDIR/bench_startup.md" 2>&1
echo ""

# --- binary size & RSS ---
echo "--- Binary size ---"
ls -lh "$NJQ" "$JQ" | awk '{print $5, $NF}'
echo ""

echo "--- Peak RSS (1MB file) ---"
echo -n "nanojq: "
/usr/bin/time -v "$NJQ" '.count' "$TMPDIR/1mb.json" 2>&1 >/dev/null | grep "Maximum resident"
echo -n "jq:     "
/usr/bin/time -v "$JQ" -r '.count' "$TMPDIR/1mb.json" 2>&1 >/dev/null | grep "Maximum resident"

echo ""
echo "=== benchmark complete ==="
