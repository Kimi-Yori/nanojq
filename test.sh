#!/bin/bash
# nanojq basic tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$SCRIPT_DIR/nanojq" ]; then
    NJQ="$SCRIPT_DIR/nanojq"
elif [ -x "$SCRIPT_DIR/nanojq-dynamic" ]; then
    NJQ="$SCRIPT_DIR/nanojq-dynamic"
else
    echo "error: no nanojq binary found. run 'make' or 'make dynamic' first." >&2
    exit 1
fi
PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  expected: $(echo "$expected" | head -1)"
        echo "  actual:   $(echo "$actual" | head -1)"
    fi
}

check_exit() {
    local desc="$1" expected_exit="$2"
    shift 2
    set +e
    "$@" >/dev/null 2>&1
    local actual_exit=$?
    set -e
    if [ "$expected_exit" = "$actual_exit" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (exit: expected=$expected_exit actual=$actual_exit)"
    fi
}

check_stderr() {
    local desc="$1" expected_exit="$2" expected_msg="$3"
    shift 3
    set +e
    local actual_err
    actual_err=$("$@" 2>&1 >/dev/null)
    local actual_exit=$?
    set -e
    if [ "$expected_exit" = "$actual_exit" ] && echo "$actual_err" | grep -qF "$expected_msg"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (exit: expected=$expected_exit actual=$actual_exit)"
        echo "  expected msg containing: $expected_msg"
        echo "  actual stderr: $actual_err"
    fi
}

echo "=== nanojq test suite ==="

# --- basic key extraction ---
check "string value" \
    "alice" \
    "$(echo '{"name":"alice"}' | $NJQ '.name')"

check "number value" \
    "42" \
    "$(echo '{"age":42}' | $NJQ '.age')"

check "boolean true" \
    "true" \
    "$(echo '{"ok":true}' | $NJQ '.ok')"

check "boolean false" \
    "false" \
    "$(echo '{"ok":false}' | $NJQ '.ok')"

check "null value" \
    "null" \
    "$(echo '{"x":null}' | $NJQ '.x')"

# --- nested keys ---
check "nested key" \
    "bar" \
    "$(echo '{"a":{"b":"bar"}}' | $NJQ '.a.b')"

check "deep nested" \
    "deep" \
    "$(echo '{"a":{"b":{"c":"deep"}}}' | $NJQ '.a.b.c')"

# --- array index ---
check "array index 0" \
    "first" \
    "$(echo '{"items":["first","second"]}' | $NJQ '.items[0]')"

check "array index 1" \
    "second" \
    "$(echo '{"items":["first","second"]}' | $NJQ '.items[1]')"

check "top-level array" \
    "hello" \
    "$(echo '["hello","world"]' | $NJQ '.[0]')"

# --- mixed path ---
check "mixed key+index" \
    "alice" \
    "$(echo '{"users":[{"name":"alice"}]}' | $NJQ '.users[0].name')"

# --- LLM API response pattern ---
check "OpenAI response pattern" \
    "Hello world" \
    "$(echo '{"choices":[{"message":{"content":"Hello world"}}]}' | $NJQ '.choices[0].message.content')"

# --- root ---
check "bare dot (root object)" \
    '{"a":1}' \
    "$(echo '{"a":1}' | $NJQ '.')"

# --- escape sequences ---
check "escaped newline" \
    "$(printf 'line1\nline2')" \
    "$(printf '{"t":"line1\\nline2"}' | $NJQ '.t')"

check "escaped tab" \
    "$(printf 'a\tb')" \
    "$(printf '{"t":"a\\tb"}' | $NJQ '.t')"

check "escaped quote" \
    'say "hi"' \
    "$(printf '{"t":"say \\"hi\\""}' | $NJQ '.t')"

# --- unicode escape ---
check "unicode BMP" \
    "$(printf '\xe3\x83\xab\xe3\x83\x8a')" \
    "$(printf '{"name":"\\u30eb\\u30ca"}' | $NJQ '.name')"

# --- JSON output mode ---
check "--json flag" \
    '"alice"' \
    "$(echo '{"name":"alice"}' | $NJQ --json '.name')"

check "-J flag" \
    '"alice"' \
    "$(echo '{"name":"alice"}' | $NJQ -J '.name')"

# --- object/array as-is output ---
check "object output" \
    '{"b":2}' \
    "$(echo '{"a":{"b":2}}' | $NJQ '.a')"

check "array output" \
    '[1,2,3]' \
    "$(echo '{"a":[1,2,3]}' | $NJQ '.a')"

# --- exit codes ---
check_exit "found -> exit 0" 0 $NJQ '.name' <<< '{"name":"alice"}'
check_exit "not found -> exit 1" 1 $NJQ '.missing' <<< '{"name":"alice"}'
# jsmn is lenient with some invalid JSON (e.g. "not" parses as primitive),
# so we test with something clearly broken
check_exit "invalid json -> exit 2" 2 $NJQ '.x' <<< '{invalid'
check_exit "invalid query -> exit 2" 2 $NJQ 'bad' <<< '{"x":1}'

# --- stderr messages ---
check_stderr "stderr: invalid query" 2 "invalid query syntax" $NJQ 'bad' <<< '{"x":1}'
check_stderr "stderr: unknown option" 2 "unknown option" $NJQ '--bad' <<< '{}'
check_stderr "stderr: unexpected arg" 2 "unexpected argument" $NJQ '.x' /dev/null extra <<< '{}'

# --- file input ---
TMPFILE=$(mktemp)
echo '{"ver":"1.0"}' > "$TMPFILE"
check "file input" \
    "1.0" \
    "$($NJQ '.ver' "$TMPFILE")"
rm -f "$TMPFILE"

# --- bracket notation ---
check "bracket key with dot" \
    "dotted" \
    "$(echo '{"a.b":"dotted","a":{"b":"nested"}}' | $NJQ '.["a.b"]')"

check "bracket key vs dot notation" \
    "nested" \
    "$(echo '{"a.b":"dotted","a":{"b":"nested"}}' | $NJQ '.a.b')"

check "bracket key with spaces" \
    "val" \
    "$(echo '{"key with spaces":"val"}' | $NJQ '.["key with spaces"]')"

check "bracket key normal" \
    "works" \
    "$(echo '{"normal":"works"}' | $NJQ '.["normal"]')"

check "bracket key chained" \
    "deep" \
    "$(echo '{"a.b":{"c":"deep"}}' | $NJQ '.["a.b"].c')"

check "bracket key after dot" \
    "found" \
    "$(echo '{"a":{"b.c":"found"}}' | $NJQ '.a.["b.c"]')"

check "bracket empty key" \
    "1" \
    "$(echo '{"":1,"x":2}' | $NJQ '.[""]')"

check "bracket escaped quote key" \
    "yes" \
    "$(printf '{"\\\"":"yes"}' | $NJQ '.["\""]')"

check_exit "bracket key not found -> exit 1" 1 $NJQ '.["missing"]' <<< '{"x":1}'
check_exit "bracket unclosed -> exit 2" 2 $NJQ '.["bad' <<< '{"x":1}'

# --- multiple top-level documents ---
check_exit "multiple top-level values -> exit 2" 2 $NJQ '.x' <<< '{"x":1} {"y":2}'
check_exit "multiple primitives -> exit 2" 2 $NJQ '.' <<< '1 2'
check_stderr "stderr: multiple values" 2 "multiple top-level values" $NJQ '.' <<< '{} []'

# --- empty input ---
check_exit "empty stdin -> exit 2" 2 $NJQ '.x' <<< ''

# --- --help / --version ---
check_exit "--help exits 0" 0 $NJQ --help
check_exit "--version exits 0" 0 $NJQ --version

# --- surrogate pair ---
check "surrogate pair (U+1F600)" \
    "$(printf '\xf0\x9f\x98\x80')" \
    "$(printf '{"e":"\\uD83D\\uDE00"}' | $NJQ '.e')"

# --- null vs not found ---
check_exit "null value -> exit 0" 0 $NJQ '.x' <<< '{"x":null}'
check_exit "missing key -> exit 1" 1 $NJQ '.y' <<< '{"x":null}'

# --- summary ---
echo ""
echo "results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "all tests passed"
