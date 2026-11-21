# AI Session Viewer (Claude Code + Antigravity)

**Claude Code** (`~/.claude/projects/`) と **Google Antigravity** (`~/.gemini/antigravity-cli/`, `~/.gemini/antigravity/`) の全セッション履歴をひとつの画面で横断閲覧・検索できるローカル Mac ネイティブアプリ。読み取り専用・ネットワーク通信ゼロ・外部依存なしで動作する。

[operando/claude-session-viewer](https://github.com/operando/claude-session-viewer) をベースに、Claude Code と Antigravity の両対応へ統合した版。

## インストール・ビルド・起動

Xcode プロジェクト不要。Node.js も不要（Xcode Command Line Tools の `swiftc` のみ）。

### インストールスクリプトを使う（おすすめ）

`install.sh` でビルドから `/Applications/AISessionViewer.app` への配置まで一括で行える（`/Applications` に書き込み権限がない場合は自動で `~/Applications` へインストール）。

```sh
./install.sh --open          # ビルドして /Applications にインストールし起動
./install.sh --user --open   # ~/Applications にインストールして起動
./install.sh --uninstall     # アンインストール（お気に入りデータは保持）
```

### 手動ビルドのみ

`build.sh` が `swiftc` で直接 `.app` バンドルを生成する。

```sh
mac/native/build.sh
open mac/native/AISessionViewer.app
```

UI (`index.html`) やロジックを変更したら、`install.sh` または `build.sh` を再実行してアプリを起動し直せば反映される。

## 主な機能

3ペイン構成: プロジェクト（作業ディレクトリ単位で Claude Code / Antigravity を自動統合）→ セッション → 会話。

- **ソース切り替え** — ヘッダーの `すべて` / `Claude` / `Antigravity` ボタンでプロジェクト・セッション・検索結果を即座にフィルタリング。同じ作業ディレクトリ (`cwd`) のセッションは同一プロジェクト配下に統合表示され、各セッションに `Claude` / `AGY` バッジが付く
- **会話表示** — チャット風（ユーザー入力は右寄せ、AI応答は左寄せでMarkdown整形）。右下の `↓` ボタンで最下部へ即ジャンプ。各応答ホバー時の `⧉` でその応答だけをMarkdownコピー
- **全セッション横断検索** — `⌘F` で検索ボックスにフォーカス、`Enter` で Claude Code / Antigravity を横断検索。結果はプロジェクト欄に「🔍 `<検索語>`」として積まれ、開いた会話ではヒット箇所をハイライト表示
- **お気に入り** — セッション項目の `☆` で登録/解除。プロジェクト欄最上部の「★ お気に入り」からツール・プロジェクト横断でアクセス
- **再開コマンドコピー** — セッション項目の `⧉` でツールに応じた再開コマンドをコピー
  - Claude Code: `cd '<cwd>' && claude --resume '<セッションID>'`
  - Antigravity: `cd '<cwd>' && agy --conversation '<セッションID>'`
- **Markdown出力** — ヘッダーの「MD出力」で表示中のやり取りをチェックボックス状態込みでMarkdown化しクリップボードへコピー

ヘッダーのチェックボックス（すべてデフォルトOFF）:

- **途中の応答** — 途中経過の応答と `thinking`。OFFなら各入力に対する最終応答のみ
- **システム注入** — Claude Code の `<task-notification>` / `<system-reminder>` や Antigravity の `<SYSTEM_MESSAGE>` / 付加メタデータ
- **ツール操作** — Bash / Write / `run_command` / `read_file` 等のツール呼び出しと結果（折りたたみ展開）
- **サブエージェント** — Claude Code の sidechain および Antigravity の子セッション（`invoke_subagent`）を展開表示

## データとセキュリティ

- 参照するのは `~/.claude/projects/`、`~/.gemini/antigravity-cli/`、`~/.gemini/antigravity/` のみ（読み取り専用）
- お気に入りだけ `~/Library/Application Support/ai-session-viewer/favorites.json`（パーミッション `0600`）に保存
- ローカル HTTP サーバーは立てず、WKWebView の JS ブリッジのみで完結。厳格な CSP（`connect-src 'none'`）、生 HTML エスケープ、危険 URL スキーム無効化、外部画像自動読み込み抑止、WebView 外部遷移ブロックを実装

## 開発

アーキテクチャ・データ仕様・セキュリティおよびメモリ管理の約束事は [AGENTS.md](AGENTS.md)（およびシンボリックリンク [CLAUDE.md](CLAUDE.md)）を参照。

## ライセンス

MIT ([LICENSE](LICENSE))。Markdown表示に [marked](https://github.com/markedjs/marked) v12.0.2 (MIT, Copyright (c) 2011-2024, Christopher Jeffrey) を同梱している。
