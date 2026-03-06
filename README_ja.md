<table>
    <thead>
        <tr>
            <th style="text-align:center"><a href="README.md">English</a></th>
            <th style="text-align:center">日本語</th>
        </tr>
    </thead>
</table>

# nanojq

LLMエージェントパイプライン向け、超軽量JSONセレクタCLI。

jq風の構文でJSONから値を抽出します。外部依存ゼロ、staticバイナリ **22 KB**。起動速度が重要なシェルパイプライン、エージェントツールチェーン、組み込み環境向けに設計されています。

## なぜ nanojq？

| | nanojq | jq 1.7 |
|---|---|---|
| バイナリサイズ | **22 KB** | 31 KB |
| 起動時間（1 KB入力） | **447 µs** | 3.4 ms |
| 起動時間（stdin） | **679 µs** | 3.7 ms |
| Peak RSS（1 MB入力） | **1.6 MB** | 9.0 MB |
| 外部依存 | **なし** | なし |

小〜中サイズのJSONで **5〜10倍高速**。大きなファイル（1 MB以上）ではjqの最適化されたパーサが勝ちます。nanojqはファストパス向けであり、汎用ツールではありません。

## インストール

```bash
# ソースからビルド（最小staticバイナリにはmusl-gccが必要）
git clone https://github.com/Kimi-Yori/nanojq.git
cd nanojq
make              # → 22 KB staticバイナリ

# システムccでも可（バイナリは大きくなるが動作は高速）
make dynamic      # → nanojq-dynamic

# テストとインストール（どちらのバイナリでもOK）
make test
sudo make install
```

## 使い方

```bash
# オブジェクトキー
echo '{"name":"alice"}' | nanojq '.name'
# → alice

# ネストキー
echo '{"a":{"b":{"c":42}}}' | nanojq '.a.b.c'
# → 42

# 配列インデックス
echo '{"items":[10,20,30]}' | nanojq '.items[1]'
# → 20

# 混合パス
curl -s $API | nanojq '.choices[0].message.content'

# ファイル入力
nanojq '.version' package.json

# ルートドキュメント
echo '[1,2,3]' | nanojq '.'
# → [1,2,3]

# ブラケット記法（ドットやスペースを含むキー）
echo '{"a.b":1}' | nanojq '.["a.b"]'
# → 1

# JSON出力（クォート付き）
echo '{"name":"alice"}' | nanojq --json '.name'
# → "alice"
```

## クエリ構文

```
.key              オブジェクトキー
.key.subkey       ネストキー
.[0]              配列インデックス
.["key"]          ブラケットキー（ドット・スペースを含むキー用）
.key[0].name      混合パス
.                 ルート（ドキュメント全体）
```

### 非対応（設計上の判断）

- `|` パイプ
- `.[]` 配列展開
- `.[-1]` 負インデックス
- `select()`、`map()`、`if` 等のフィルタ

nanojqは、実際の抽出タスクの約80%をカバーするjq構文の約20%を意図的にサポートしています。

## 出力

- **デフォルト**: raw — 文字列はクォートなし、エスケープシーケンス解除済み
- **`--json` / `-J`**: JSON表現 — 文字列はクォート付き
- オブジェクト・配列は元の入力からそのまま出力（再フォーマットなし）
- 数値はそのまま通過（float変換なし）
- 末尾に改行を自動付与

> 注: jqのデフォルトはJSON出力で`-r`がraw。nanojqはシェルパイプライン用途のためrawがデフォルトです。

## 終了コード

| コード | 意味 |
|--------|------|
| 0 | 値が見つかった |
| 1 | パスが見つからない |
| 2 | エラー（不正JSON、不正クエリ、I/O） |

## 仕組み

```
stdin/file → [Read] → [Tokenize] → [Walk] → [Output]
                          │              │
                    jsmn方式          JSON Pointer
                    single-pass      パスマッチング
                    zero-alloc
```

- **Tokenize**: [jsmn](https://github.com/zserge/jsmn)でDOM構築なしにトークン境界をスキャン
- **Walk**: クエリのパスセグメントをトークンツリーに対して線形1パスでマッチング
- **Output**: マッチした位置の元入力スライスを抽出 — シリアライズのオーバーヘッドなし

`stdio.h`不使用、`stdlib.h`不使用。全I/Oは`write(2)`、全メモリ確保は`mmap(2)`。

## ビルドターゲット

```bash
make              # staticリリース（musl-gcc、22 KB）
make dynamic      # dynamicリリース（システムcc）
make debug        # デバッグビルド（シンボル付き）
make test         # テストスイート実行（48テスト）
make bench        # jqとのベンチマーク（hyperfine必要）
make clean        # ビルド成果物削除
make install      # /usr/local/bin にインストール（PREFIX変更可）
```

## ベンチマーク

[hyperfine](https://github.com/sharkdp/hyperfine)でLinux x86_64上にて計測。

| テスト | nanojq | jq 1.7 | 比率 |
|--------|--------|--------|------|
| 1 KB 単純キー | 447 µs | 3.4 ms | **7.7倍** |
| 10 KB ネストキー | 336 µs | 3.5 ms | **10.5倍** |
| 100 KB 配列+ネスト | 2.1 ms | 5.1 ms | **2.4倍** |
| 1 MB トップレベル | 59.6 ms | 26.8 ms | jq 2.2倍速 |
| stdin起動* | 679 µs | 3.7 ms | **5.4倍** |

\* stdin起動はshell + echoのオーバーヘッド込み（両ツール同条件で計測）。

`make bench` で再現可能。

## 制限事項

- 単一JSONドキュメントのみ（ストリーミング非対応）
- 計算クエリやフィルタなし
- ブラケット記法はクエリ側の`\uXXXX`エスケープを解決しない（リテラル文字を使用）
- 入力サイズ上限 256 MiB（stdin）/ 2 GiB（ファイル）

## 謝辞

- [jsmn](https://github.com/zserge/jsmn) — Serge Zaitsevによる最小JSONトークナイザ
- [AssemblyClaw](https://github.com/gunta/AssemblyClaw) — このプロジェクトの着想源となったARM64アセンブリAIエージェントCLI

## ライセンス

MIT
