# AI Session Viewer — Agent Guide

`~/.claude/projects/`（Claude Code）と `~/.gemini/antigravity-cli/`・`~/.gemini/antigravity/`（Google Antigravity）のセッション履歴を統合閲覧するローカル Mac ネイティブアプリ。読み取り専用・外部依存なし・ネットワーク通信なし（お気に入りファイル以外、ユーザーデータには一切書き込まない）。

## 開発・セキュリティ上の約束事

### 個人情報・個人環境を持ち込まない

- コード・コメント・ドキュメント・コミットメッセージに、実在のユーザー名・ホームパス・セッション ID・会話内容を書かない。例示は `/Users/you/...` や `~` などの汎用形にする
- 動作確認は開発者自身のトランスクリプトで行うため、確認結果（スクリーンショット・API レスポンス・ログ）をそのままドキュメントや PR / issue に貼らない
- デバッグ用の一時ファイルやビルド済み `.app` バンドルをコミットしない（`.gitignore` の `*.app/` `*.log` `.DS_Store` を維持）
- 新しい設定や出力ファイルを保存する場合は `~/Library/Application Support/ai-session-viewer/` に統一し（ファイル `0600` / ディレクトリ `0700`）、リポジトリ内に成果物を書かない

### 個人環境に依存した実装をしない

- ホームパスを `/Users/<名前>` 固定にしない（`FileManager.default.homeDirectoryForCurrentUser` を使う）
- 特定マシン固有のツールパスを前提にしない
- Bundle ID や識別子に個人名を入れない（現在は `local.ai-session-viewer`）

### セキュリティ（脅威モデル）

**トランスクリプトは信用できない入力**として扱う。Web ページ経由の prompt injection 等により、閲覧対象のセッション内容に悪意ある HTML・リンク・画像・コマンド文字列が混入している可能性がある。

- **CSP の維持**: `index.html` の `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'; base-uri 'none'; form-action 'none';">` を緩めない
- **DOM エスケープ**: `index.html` の表示系では必ず `esc()` を通す。生の文字列を `innerHTML` に直接入れない
- **Markdown レンダラの制限を外さない** (`index.html` の `marked.use`):
  - `html()`: 生 HTML タグをエスケープ
  - `link()`: `http:` / `https:` のみ許可（`javascript:` / `file:` / `data:` 等を無効化）し `rel="noopener noreferrer" target="_blank"` を付与
  - `image()`: 外部への自動リクエスト（トラッキング / 情報漏洩）を防ぐため `<img>` を出さずテキスト表示にする
- **WKWebView の封じ込め (`App.swift`)**:
  - `WebNavigationGuard` (`WKNavigationDelegate` / `WKUIDelegate`) により、バンドル内 `index.html` 以外への WebView 内遷移をすべて `.cancel` する（`http:` / `https:` リンククリック時のみ `NSWorkspace.shared.open` で外部ブラウザへ逃がす）
  - `ApiBridge` で `message.frameInfo.isMainFrame` かつ `request.url?.standardizedFileURL == allowedURL` 以外の呼び出しをすべて拒否する
- **パラメータ検証 (`Engine.swift`)**:
  - `project` / `id`: `^[A-Za-z0-9._-]+$` かつ `.` / `..` を含まないことを検証
  - `source`: ホワイトリスト（`claude` / `antigravity`、フィルタは + `all`）
- **再開コマンドコピー (`index.html`)**: `cwd`・`id` の両方に `shellQuote()` を適用し、改行文字（`\r`/`\n`）を除去する
- **読み取り専用の徹底**: `~/.claude/` および `~/.gemini/` 配下には一切書き込まない。SQLite を WAL モード対策で `SQLITE_OPEN_READWRITE` にフォールバックする際も必ず `PRAGMA query_only = ON;` の戻り値が `SQLITE_OK` であることを確認する
- **依存最小化**: 外部パッケージ依存を増やさない。ライブラリが必要な場合は `marked.min.js` のようにファイル同梱し、バージョン・出典・ライセンスを `README.md` に記録する

## アーキテクチャ

- **データ層**: `mac/native/Sources/Engine.swift`（Swift 標準 + macOS 標準 `SQLite3`）
- **UI シェル**: `mac/native/Sources/App.swift`（SwiftUI + `WKWebView` + `WKScriptMessageHandler` JS ブリッジ）
- **UI 本体**: `index.html` + `marked.min.js`（ビルド時に `.app/Contents/Resources/` に同梱）
- ローカル HTTP サーバーは持たず、`window.webkit.messageHandlers.api` のみで通信する

## ファイル構成

```text
ai-session-viewer/
├── index.html                        # 3ペインUI (バンドルに同梱)
├── marked.min.js                     # Markdownパーサ v12.0.2 (MIT, 同梱)
├── install.sh                        # ビルド + /Applications (or ~/Applications) へのインストール
├── AGENTS.md                         # 本ドキュメント (CLAUDE.md はシンボリックリンク)
├── README.md                         # 利用者向けドキュメント
├── LICENSE                           # MIT License
└── mac/native/
    ├── build.sh                      # swiftc で AISessionViewer.app を直接生成
    ├── Assets/
    │   ├── AppIcon.svg               # アプリアイコン (Origami Bird) マスターSVG
    │   └── AppIcon.icns              # マルチ解像度 macOS アイコン
    └── Sources/
        ├── App.swift                 # SwiftUI + WKWebView + ApiBridge + WebNavigationGuard
        └── Engine.swift              # Claude Code + Antigravity 統合データエンジン
```

## ビルド・インストール・起動

```sh
mac/native/build.sh                   # Macアプリをビルド (mac/native/AISessionViewer.app)
./install.sh --open                   # ビルドして /Applications へインストールし起動
./install.sh --user --open            # ~/Applications へインストールして起動
./install.sh --uninstall              # インストール済み .app を削除 (お気に入りは保持)
```

- `index.html` や `Sources/*.swift` を変更したら、**`mac/native/build.sh`（または `./install.sh`）の再実行とアプリ再起動**が必要（HTML は `.app/Contents/Resources/` にコピーされるため）
- テスト用環境変数（`Engine.swift` が参照）:
  - `CLAUDE_PROJECTS_DIR`: Claude Code セッションディレクトリの上書き
  - `ANTIGRAVITY_HOME`: Antigravity データディレクトリの上書き（カンマ区切りで複数指定可）

## 内部 API 仕様 (`Engine.handle(path:)`)

- `GET /api/projects[?source=all|claude|antigravity]`
  - 返却: `[{ name, cwd, count, claudeCount, antigravityCount, lastModified }]`
- `GET /api/sessions?project=<id>[&source=all|claude|antigravity]`
  - 返却: `[{ id, source, project, size, mtime, title, firstPrompt, firstTs, cwd }]`
- `GET /api/session?source=<claude|antigravity>&id=<uuid>[&sidechain=1]`
  - 返却: `[{ kind, text, ts, source, sidechain?, agentName?, subId?, model?, label?, name?, input?, inputSummary?, result?, isError? }]`
- `GET /api/search?q=<2文字以上>[&source=all|claude|antigravity]`
  - 返却: `{ sessions: [{ source, project, id, title, mtime, cwd, count, matches }], tookMs }`
- `GET /api/favorites`
  - 返却: `[{ source, project, id, addedAt, title?, mtime?, cwd?, missing? }]`
- `GET /api/favorite?source=<claude|antigravity>&project=<id>&id=<uuid>&on=1|0`
  - 返却: 更新後の保存配列 `[{ source, project, id, addedAt }]`
- `GET /api/stats`
  - 返却: `{ cacheEntries, cacheMB, cacheLimitMB, rssMB }`

## データ仕様の要点

### プロジェクト統合キー (`encodeProject`)

- 実パス（`cwd`）が取得できた場合は **UTF-8 の Base64URL**（`+`→`-`, `/`→`_`, `=`除去）をプロジェクト ID にする
- Claude Code と Antigravity で同じ作業ディレクトリ（`cwd`）を使ったセッションが自動的に同一プロジェクトへ統合され、同時にパラメータ検証にも適合する
- `cwd` が取得できない場合のフォールバック: Claude Code は `c_<dirName>`、Antigravity は `_unassigned`

### Claude Code (`~/.claude/projects/<dir>/*.jsonl`)

- 1 行 1 JSON（`type: "user" | "assistant" | "summary" | "ai-title" | ...`）
- 先頭 256KB の軽量スキャン（`claudeSessionMeta`）で `title` / `firstPrompt` / `firstTs` / `cwd` を取得（`mtime` キーでキャッシュ）
- `type: "user"` にはハーネス注入が混ざるため、開始タグと閉じタグが揃っている注入タグ（`<task-notification>` / `<system-reminder>` 等）、`isMeta: true`、`[Request interrupted` を `kind: "system"` として分離
- `tool_use` と `tool_result` は `tool_use_id` で突き合わせて 1 エントリに統合
- `isSidechain: true` の行は `sidechain=1` のときのみ含める

### Antigravity (`~/.gemini/antigravity-cli/`, `~/.gemini/antigravity/`)

- メタデータ: `conversation_summaries.db` の `conversation_summaries` テーブルから `title`, `preview`, `workspace_uris`, `agent_name`, `parent_conversation_id`, `nesting_depth` を取得。`cwd` の補完に `history.jsonl` も参照
- **SQLite WAL モードの注意点**: Antigravity 稼働中は DB が WAL モードになっており、`sqlite3_open_v2(..., SQLITE_OPEN_READONLY, nil)` が `-shm` マップで `SQLITE_CANTOPEN (14)` を返すことがある。失敗時は `SQLITE_OPEN_READWRITE` + `PRAGMA query_only = ON;`（戻り値 `SQLITE_OK` 必須）にフォールバックする
- トランスクリプト: `brain/<conversation_id>/.system_generated/logs/transcript_full.jsonl` を優先し、無ければ `transcript.jsonl` を使用
- `USER_INPUT`: `<USER_REQUEST>...</USER_REQUEST>` の中身をユーザー発言として抽出。現在時刻のみの `<ADDITIONAL_METADATA>` は除外し、それ以外の付加情報があれば `kind: "system"`（`label: "metadata"`）にする
- `PLANNER_RESPONSE`: `thinking` → `kind: "thinking"`、`content` → `kind: "assistant"`、`tool_calls` → `kind: "tool"` として FIFO キューに積み、後続の `GENERIC` ステップ（ツール結果・エラー）と順番にペアリングする
- `SYSTEM_MESSAGE`: `kind: "system"`（`label: "system-message"`）
- サブエージェント: 親セッションが存在する子セッション（`parent_conversation_id`）はセッション一覧に出さず、親セッション詳細で `sidechain=1` のときに `invoke_subagent` 結果の直後（取りこぼしがあれば末尾）へ再帰展開する

### 表示の切り詰め基準

- ツール入出力: 10,000 文字
- システム注入: 4,000 文字
- thinking: 3,000 文字

## メモリ・パフォーマンスの約束事

- ループ内で `JSONSerialization` を使う処理は必ず `autoreleasepool` で囲む（囲まないと全ファイル走査時に RSS が数百 MB 膨らむ）
- 辞書へオプショナル文字列を入れる際は必ず `opt(_:)`（`s ?? NSNull()`）を通し、コンパイラ警告および `JSONSerialization` でのクラッシュを防ぐ
- 検索キャッシュは `mtime` キー + 合計サイズ上限付き LRU（デフォルト 200MB）。`GET /api/stats` で現在のキャッシュ量と RSS を確認できる

## 変更後の検証チェックリスト

1. **構文チェック & 警告ゼロビルド**:
   ```sh
   bash -n install.sh mac/native/build.sh
   mac/native/build.sh
   ```
2. **Engine.swift 単体テスト**:
   - 一時的な CLI ハーネス（`Engine.handle(path:)` を呼ぶだけの `@main`）で `/api/projects`, `/api/sessions`, `/api/session` (`sidechain=0/1`), `/api/search`, 不正パラメータ拒否（`..` を含む値や不正 `source`）を検証する
3. **インストール・実機確認**:
   - `./install.sh --open` で `/Applications/AISessionViewer.app` を更新・起動し、UI とセキュリティ制約（外部リンクがデフォルトブラウザで開くこと等）を確認する
