<table>
    <thead>
        <tr>
            <th style="text-align:center">English</th>
            <th style="text-align:center"><a href="README_ja.md">日本語</a></th>
        </tr>
    </thead>
</table>

# nanojq

Ultra-lightweight JSON selector CLI for LLM agent pipelines.

nanojq extracts values from JSON using jq-like syntax, with zero dependencies and a **22 KB** static binary. It's designed for scenarios where startup time matters more than query complexity — shell pipelines, agent tool chains, and embedded environments.

## Why nanojq?

| | nanojq | jq 1.7 |
|---|---|---|
| Binary size | **22 KB** | 31 KB |
| Startup (1 KB input) | **447 µs** | 3.4 ms |
| Startup (stdin) | **679 µs** | 3.7 ms |
| Peak RSS (1 MB input) | **1.6 MB** | 9.0 MB |
| Dependencies | **none** | none |

nanojq is **5-10x faster** on small-to-medium JSON. For large files (1 MB+), jq's optimized parser wins — nanojq is built for the fast-path, not the general case.

## Install

```bash
# Build from source (requires musl-gcc for minimal static binary)
git clone https://github.com/Kimi-Yori/nanojq.git
cd nanojq
make              # → 22 KB static binary

# Or with system cc (larger binary, still fast)
make dynamic      # → nanojq-dynamic

# Test and install (works with either binary)
make test
sudo make install
```

## Usage

```bash
# Object key
echo '{"name":"alice"}' | nanojq '.name'
# → alice

# Nested key
echo '{"a":{"b":{"c":42}}}' | nanojq '.a.b.c'
# → 42

# Array index
echo '{"items":[10,20,30]}' | nanojq '.items[1]'
# → 20

# Mixed path
curl -s $API | nanojq '.choices[0].message.content'

# File input
nanojq '.version' package.json

# Root document
echo '[1,2,3]' | nanojq '.'
# → [1,2,3]

# Bracket notation (keys with dots or spaces)
echo '{"a.b":1}' | nanojq '.["a.b"]'
# → 1

# JSON output (quoted strings)
echo '{"name":"alice"}' | nanojq --json '.name'
# → "alice"
```

## Query Syntax

```
.key              object key
.key.subkey       nested key
.[0]              array index
.["key"]          bracket key (for dots/spaces in keys)
.key[0].name      mixed path
.                 root (whole document)
```

### Not supported (by design)

- `|` pipe
- `.[]` array iteration
- `.[-1]` negative index
- `select()`, `map()`, `if` and other filters

nanojq intentionally covers the ~20% of jq syntax that handles ~80% of real-world extraction tasks.

## Output

- **Default**: raw — strings are unquoted, escape sequences decoded
- **`--json` / `-J`**: JSON representation — strings are quoted
- Objects and arrays are printed as-is from the original input (no reformatting)
- Numbers are passed through verbatim (no float conversion)
- A trailing newline is always appended

> Note: This is the opposite of jq, where JSON output is the default and `-r` gives raw output. nanojq defaults to raw because it's designed for shell pipelines.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Value found |
| 1 | Path not found |
| 2 | Error (invalid JSON, invalid query, I/O) |

## How It Works

```
stdin/file → [Read] → [Tokenize] → [Walk] → [Output]
                          │              │
                    jsmn-based       JSON Pointer
                    single-pass      path matching
                    zero-alloc
```

- **Tokenize**: Uses [jsmn](https://github.com/zserge/jsmn) to scan token boundaries without building a DOM
- **Walk**: Matches query path segments against the token tree in a single linear pass
- **Output**: Extracts the matched slice from the original input — no serialization overhead

No `stdio.h`, no `stdlib.h`. All I/O through `write(2)`, all allocation through `mmap(2)`.

## Build Targets

```bash
make              # Static release (musl-gcc, 22 KB)
make dynamic      # Dynamic release (system cc)
make debug        # Debug build with symbols
make test         # Run test suite (48 tests)
make bench        # Benchmark against jq (requires hyperfine)
make clean        # Remove build artifacts
make install      # Install to /usr/local/bin (PREFIX configurable)
```

## Benchmarks

Measured with [hyperfine](https://github.com/sharkdp/hyperfine) on Linux x86_64.

| Test | nanojq | jq 1.7 | Ratio |
|------|--------|--------|-------|
| 1 KB simple key | 447 µs | 3.4 ms | **7.7x** |
| 10 KB nested key | 336 µs | 3.5 ms | **10.5x** |
| 100 KB array + nested | 2.1 ms | 5.1 ms | **2.4x** |
| 1 MB top-level key | 59.6 ms | 26.8 ms | jq 2.2x faster |
| stdin startup* | 679 µs | 3.7 ms | **5.4x** |

\* stdin startup includes shell + echo overhead (both tools measured equally).

Run `make bench` to reproduce.

## Limitations

- Single JSON document only (no streaming)
- No computed queries or filters
- Bracket notation does not resolve `\uXXXX` escapes in query keys (use literal characters)
- Input size capped at 256 MiB (stdin) / 2 GiB (file)

## Acknowledgements

- [jsmn](https://github.com/zserge/jsmn) — minimal JSON tokenizer by Serge Zaitsev
- [AssemblyClaw](https://github.com/gunta/AssemblyClaw) — ARM64 assembly AI agent CLI that inspired this project

## License

MIT
