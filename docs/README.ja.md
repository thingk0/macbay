<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../Assets/brand/macbay-symbol-dark.svg">
    <img src="../Assets/brand/macbay-symbol-color.svg" width="140" height="140" alt="MacBay logo">
  </picture>
</p>

<h1 align="center">MacBay</h1>

<p align="center">
  <a href="../README.md">English</a> •
  <a href="README.ko.md">한국어</a> •
  <a href="README.zh.md">简体中文</a> •
  <a href="README.ja.md">日本語</a>
</p>

MacBayは、Apple Silicon Mac向けに設計された開発者ファーストなストレージ外部化ツールです。大容量アプリケーション、Xcode DeviceSupportデータ、各種開発者キャッシュを外部APFSドライブへ安全に移行しながら、ターミナルCLI、LaunchAgent、macOS Dock向けに元のパスを透過的に維持します。

[![CI](https://github.com/thingk0/macbay/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/thingk0/macbay/actions/workflows/ci.yml?query=branch%3Amain)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-orange.svg)](https://en.wikipedia.org/wiki/Apple_silicon)

---

## 主な機能

- **インタラクティブTUIモード（`mb` / `mb tui`）**: ターミナルで `mb` を入力するだけでキーボード操作のTUIを開きます。ストレージ容量の確認、アプリ候補の探索（Safe/Review/Blockedバッジ）、安全なdry-runプレビューと移動・復元、診断結果と問題別推奨アクションの確認が行えます。
- **アプリケーションの外部化（`dock` / `undock` / `adopt`）**: 大容量アプリを外部ストレージへ移行・内蔵ディスクへ復元、または内蔵復元を経ることなく既存の外部アプリをMacBay標準構造へ取り込みます。DockアイコンやLaunchServicesの登録も自動的に更新されます。
- **安全性判定エンジン（`AppInspector`）**: アプリケーションバンドルを自動検査し、仮想化エンタイトルメント、カーネル／システム拡張機能、ハードコードされた自己移動シグナルを検出します。
- **Xcode DeviceSupportの管理（`xcode`）**: Xcodeの正常な動作を維持したまま、肥大化しやすいiOS DeviceSupportシンボルを外部ストレージへオフロードします。既存のレガシーリンクを保持し、利用不可となったシミュレータのクリーンアップも行います。
- **任意ディレクトリの外部化（`move` / `unmove`）**: ゲームライブラリ、VMディスク、データセット、メディアフォルダなど、あらゆるディレクトリを `<Volume>/MacBay/Data/` へ移動し、アプリと同じマニフェスト追跡シンボリックリンクモデルで管理します。
- **開発者キャッシュのルーティング（`cache`）**: `~/.zshrc` 内に独立した管理ブロックを追加し、npm、pnpm、Yarn、bun、uv、pip、Gradle、CocoaPods、Goモジュール、Androidユーザーデータ、Homebrewダウンロード、Hugging Faceのキャッシュを外部ストレージへルーティングします。
- **セルフクリーンアップ（`teardown`）**: アンインストール前に、管理する全てのアプリとディレクトリの復元、管理キャッシュリンクと `~/.zshrc` ブロックの削除、デフォルトボリュームの忘却を1コマンドで実行します。
- **厳格なボリューム検証**: 外部APFSファイルシステムを自動検証し、インストーラーDMG、読み取り専用ドライブ、内蔵ディスクを安全に除外・拒否します。

---

## 対応環境

- **macOS**: 13 (Ventura) 以降
- **ハードウェア**: Apple Silicon (M1 / M2 / M3 / M4)
- **外部ストレージ**: **APFS** フォーマットされた物理外部SSD/HDD（GUIDパーティションマップ、書き込み可能）
- **開発ツール**: Xcode Command Line Tools (`xcode-select --install`)

---

## インストール方法

### 方法1: Homebrew（推奨）

Homebrewを使用してMacBayをインストールします:

```sh
brew install thingk0/tap/macbay
mb --help
```

Homebrewは、Apple Silicon（macOS 13以降）向けのタグ付きソースリリースから直接バイナリをビルドします。`mb` コマンドおよび `macbay` エイリアスの両方がHomebrewの `bin` ディレクトリにインストールされます。

#### Homebrew経由のアップデート

```sh
brew update
brew upgrade macbay
```

#### Homebrew経由のアンインストール

> [!CAUTION]
> `brew uninstall macbay` はCLI実行ファイル（`mb` および `macbay`）を削除するだけです。外部ストレージに移動したアプリケーションの復元や、`~/.zshrc` に設定されたキャッシュリダイレクトのリセットは**自動的には行われません**。
>
> **MacBayをアンインストールする前に**、1コマンドで管理対象をすべて復元してください:
> 1. teardownを実行（まず `--dry-run` でプレビュー）:
>    ```sh
>    mb teardown --dry-run
>    mb teardown
>    ```
>    dockしたアプリとmoveしたディレクトリを復元し、管理キャッシュリンクを削除し、`~/.zshrc` ブロックを消去し、デフォルトボリュームを忘れます。
> 2. クリーンアップ完了後、Formulaを安全にアンインストール:
>    ```sh
>    brew uninstall macbay
>    ```
>
> 手動でクリーンアップする場合は、dockした各アプリに `mb undock <AppName>.app`、moveした各ディレクトリに `mb unmove <path>`、そして `mb cache --reset` を実行してください。

---

### 方法2: ソースからビルド

要件: macOS 13以降、Apple Silicon、Xcode Command Line Tools または Xcode 15.3以降（Swift 5.10以降が利用可能であること）。

```sh
# リポジトリのクローン
git clone https://github.com/thingk0/macbay.git
cd macbay

# リリースバイナリのビルド
swift build -c release

# テストの実行
swift test

# /usr/local/bin へコピー（任意）
sudo cp .build/release/mb /usr/local/bin/mb
sudo ln -sf /usr/local/bin/mb /usr/local/bin/macbay
```

インストールの確認:

```sh
mb --version
# 出力例: 1.2.1
```

---

## クイックスタート

### 0. インタラクティブTUIモード（デフォルト）

対話型ターミナルで引数を付けずに `mb` を実行すると、キーボード操作のTUIが起動します:

```sh
mb
# または明示的に実行:
mb tui
```

> [!NOTE]
> 非対話型環境（スクリプト、CI、パイプ経由）や `TERM` が非対応の場合は、標準のCLIヘルプを出力して終了します。非対話型環境で `mb tui` を実行するとエラーメッセージを表示して終了します。

#### キーボード操作

| キー | 操作 |
| --- | --- |
| `↑` / `↓` または `j` / `k` | メニューやリストの移動 |
| `Enter` | メニューの選択・アクションの実行 |
| `Esc` | 前の画面に戻る |
| `q` | MacBay TUIの終了 |
| `r` | 現在の画面のデータを再読み込み |
| `←` / `→` または `Tab` | 確認ダイアログのボタン切り替え（Cancel / Confirm） |

#### TUIの対象範囲

- **ホーム**: 内蔵および外部APFSディスクの容量、MacBay管理下のアプリ数を確認。
- **アプリ移動（`dock`）**: スキャン基準によるサイズ順一覧、`[Safe]` / `[Review]` / `[Blocked]` 互換性バッジを表示。詳細パス・互換性根拠の確認、セッション対象ボリュームの選択、空き容量予測を含むdry-runプレビューと実行確認。（Review対象はリスク確認・承認後に `--force` で安全に移行）
- **アプリ復元（`undock`）**: 接続中のボリュームにあるMacBay管理アプリを内蔵 `/Applications` に復元。非管理アプリはこの画面からそのまま登録できます。現在の場所、標準保存先、リンク変更、ファイル移動の有無を確認して実行すると、復元プレビューが準備されます。登録先はアプリが実際にあるボリュームで、設定済みの既定ボリュームへ勝手に変更されることはありません。未確認項目や壊れたリンクは状態と `mb doctor` の案内を表示します。
- **診断（`doctor`）**: 外部化したアプリと開発者データのリンク切れ、対象欠落、記録不一致、中断された操作を確認し、問題ごとの推奨アクションを把握します。
- **検索・フィルター**: 移動・復元リストで `/` を押して名前を検索します。Enterで適用、Escで検索を解除します。`f` は互換性チェック通過アプリ／管理対象のみ、`s` は名前・サイズ順、`c` は検索とフィルターの解除です。
- **コピー進捗**: コピー先のファイルサイズから容量・割合・平均増加速度を推定します。事前割り当ての影響があるため検証済み転送量ではありません。コピー中は100%を表示せず、署名検証は別段階です。計測できない場合は段階と経過時間を表示します。
- **診断から復旧**: 重複アプリの診断で `p` を押すと比較と再移動／ローカル保持のプレビューを開きます。中断したrepairは `b` で対応するジャーナルとロールバックを確認します。実行には別途確認が必要で、初期選択はキャンセルです。リスクがある場合は明示的な承諾が必要です。`r` で再診断します。adoptの中断にはrepairのロールバックを適用しません。
- 複数選択とXcode／キャッシュのTUI実行は今後の予定です。現在はCLIを使用してください。

### 1. ストレージ状態の確認

内蔵ドライブの空き容量、マウントされている外部ボリューム、および移行対象外のドライブを確認します:

```sh
mb status
```

出力例:
```text
MacBay storage status

Internal · Macintosh HD
  /
  ████████░░░░░░░░░░░░  42.2% used
  Used: 96.3 GB / 228.3 GB
  Free: 132.0 GB

External · ExternalSSD
  /Volumes/ExternalSSD
  ████░░░░░░░░░░░░░░░░  20.5% used
  Used: 205.0 GB / 1000.0 GB
  Free: 795.0 GB

Docked items · 0
  None

Warnings · 2
  • Excluded volume 'InstallerImage' (/Volumes/InstallerImage): Disk image volumes are not supported
  • Excluded volume 'ToolInstaller' (/Volumes/ToolInstaller): Disk image volumes are not supported
```

### 2. 外部化候補の検出

大容量アプリケーション、開発者キャッシュ、すでに外部化されたアプリ、および壊れたリンクをスキャンします:

```sh
mb scan
```

出力例:
```text
MacBay scan
8 apps · 2 caches · 2 external
App threshold: 200.0 MB

Applications · 8
  NAME                    SIZE  STATUS
  HeavyStudio.app       2.1 GB  Review
  VirtualMachine.app    1.8 GB  Blocked
  ContainerRuntime.app  1.2 GB  Blocked
  DeveloperIDE.app    850.0 MB  Safe
  CloudStorage.app    620.4 MB  Safe
  SystemHelper.app    410.2 MB  Review
  DriverDaemon.app    320.0 MB  Blocked
  Messenger.app       240.5 MB  Safe

  Safe: no relocation signals detected
  Review: check compatibility details before using --force
  Blocked: migration not allowed

Developer caches · 2
  CoreSimulator  191.5 MB
  npm cache      124.2 MB

Already external · 2
  DesignKit.app    1.5 GB  Unmanaged
    → /Volumes/ExternalSSD/Applications/DesignKit.app
  AudioEngine.app  1.2 GB  MacBay
    → /Volumes/ExternalSSD/MacBay/Applications/AudioEngine.app

  MacBay: recorded in volume manifest
  Unmanaged: no matching MacBay migration record
```

完全なアプリケーションパスや互換性評価の根拠・証拠を確認するには:
```sh
mb scan --verbose
```

- **対象アプリ（Applications）**: 内蔵ディスク上の大容量アプリ（200 MB以上）と互換性ステータス（`Safe`、`Review`、`Blocked`）。
- **開発者キャッシュ（Developer caches）**: 大容量の開発ツールキャッシュ（CoreSimulator、npm cacheなど）。
- **外部化済みアプリ（Already external）**: すでに外部ストレージへ移行済みのアプリケーション:
  - `MacBay`: 外部ボリュームの `manifest.json` に記録され、MacBay が管理しているアプリ。
  - `Unmanaged`: 手動または他のツールで移動され、MacBay の記録にない未管理アプリ。
  - `Unconfirmed`: 外部ボリューム上にあるものの、マニフェスト読み取りに失敗した状態。
- **未解決リンク（Unresolved links）**: リンク先が存在しない（`Target unavailable`）、循環リンク、ボリューム確認エラーなどの異常なリンク。

### 3. リンクと記録の診断

アプリケーションリンク、開発者キャッシュのリンク、接続中のボリュームに記録された MacBay の記録が実際の状態と一致しているかを確認します。`doctor` は読み取り専用で、ファイルを変更しません:

```sh
mb doctor
```

出力例:
```text
MacBay doctor

Volumes consulted · 1
  • ExternalSSD (/Volumes/ExternalSSD) — 2 records

Needs attention · 1
  ! OfflineApp.app — Target unavailable: /Volumes/ExternalSSD/MacBay/Applications/OfflineApp.app
    Next: Reconnect the volume or confirm the path exists, then run 'mb doctor' again.

Healthy · 2
  • AudioEngine.app → /Volumes/ExternalSSD/MacBay/Applications/AudioEngine.app [MacBay]
  • LegacyTool.app → /Volumes/Backup/LegacyTool.app [unmanaged]
```

- `Healthy`: リンクが正しく解決され、MacBay の記録または想定されたレイアウトと一致しています。記録のないリンクは問題ではなく `unmanaged` 情報として表示します。
- `Needs attention`: リンク切れ、循環リンク、記録されたリンク先と実際のリンク先の不一致、記録された外部コピーやソースパスの消失、リンクであるべき場所に通常のファイルやディレクトリが現れた場合。
- `Unable to verify`: リンク、リンク先のボリューム、ボリュームの `manifest.json` を読み取れなかった場合（権限エラーやマニフェスト破損など）。
- `Notes`: 検査範囲を示します。手動で移動した項目は MacBay の履歴がないため評価対象外であり、記録を読み取れなかったボリュームの項目は検査していないことを明記します。
- `Nothing to verify`（検査対象の記録・リンクが存在しない）は「問題なし」とは区別して表示します。

終了コード: 問題なし `0`、問題または検証不能な項目の検出 `1`、診断自体の失敗（例: `--volume` パスを検査できない）`2`。

> [!NOTE]
> MacBay は接続中の外部ボリュームからしか記録を読み取らないため、取り外されたドライブは検証できません。診断は実際に確認できた範囲のみを報告し、リンク先が失われた理由をディスクの取り外しやデータ削除と断定しません。

---

## コマンドと使い方

### コマンドの短縮形

短縮形でも同じ引数とオプションを使用できます。`mb --help` でも確認できます。

| Command | Alias |
| --- | --- |
| `init` | `i` |
| `status` | `st` |
| `scan` | `sc` |
| `doctor` | `doc` |
| `references` | `refs` |
| `dock` | `dk` |
| `adopt` | `ad` |
| `undock` | `ud` |
| `repair` | `rep` |
| `xcode` | `xc` |
| `move` | `mv` |
| `unmove` | `umv` |
| `cache` | `c` |
| `teardown` | `td` |
| `tui` | `ui` |

```sh
mb st
mb sc --json
mb doc
mb dk --help
```

### デフォルトボリュームの選択（`init`）

`--volume` を省略したときに変更系コマンドが使用する外部ボリュームを保存します。`dock`、`undock`、`adopt`、`xcode`、`cache` が常に同じドライブを対象とするようになります:

```sh
# 適合するボリュームが1つだけならそのまま保存し、ターミナルでは番号付きリストから選択します
mb init

# 確認なしで特定のボリュームをデフォルトとして保存
mb init --volume /Volumes/ExternalSSD

# 保存されたデフォルトを表示
mb init --show

# 保存されたデフォルトを削除
mb init --reset
```

デフォルトはボリュームUUIDとともに `$XDG_CONFIG_HOME/macbay/config.json`（または `~/.config/macbay/config.json`）へ保存されるため、ドライブが別名でマウントされても認識されます。保存されたボリュームが接続されていない場合、変更系コマンドは他のドライブへ黙って切り替えずに停止します。`mb status` と `mb doctor` がその状態を報告し、`mb init` を再実行すると確認のうえでデフォルトを置き換えます。

### リンクと記録の診断（`doctor`）

`/Applications` のリンク、既知の開発者キャッシュのリンク、接続中の外部ボリューム（読み取り専用を含む）の MacBay 記録を検査します。ファイルや設定は変更しません:

```sh
# 接続中のボリュームとローカルリンクを診断
mb doctor

# /Volumes 以外にマウントされたボリュームを追加で検査
mb doctor --volume /Volumes/Archive
```

**検査内容**:
1. **アプリケーションリンク**: `/Applications` 内のすべてのシンボリックリンクを解決します（相対リンク、多段リンク、循環リンクを含む）。
2. **開発者キャッシュリンク**: `~/Library/Developer/Xcode/iOS DeviceSupport`、`~/Library/Developer/CoreSimulator`、`~/.npm`、`~/.cache/uv`、`~/.gradle`、`~/.cache/huggingface`。
3. **ボリューム記録**: 接続中のボリュームの `MacBay/manifest.json` と実際のソース／リンク先パスを照合します。
4. **ローカルデータ**: 記録されたソースパスがリンクではなく通常のファイルやディレクトリとして存在する場合、`Local data detected` として報告し、両方のパスと現在のサイズを表示します。外部コピーも失われている場合は単純な重複とは分類せず、記録と実際の状態の不一致として報告します。
5. **中断された操作**: ボリュームに残った未完了の `adopt`・`repair` 操作を、ロールバックや続行に必要なコマンドとともに報告します。

> [!NOTE]
> `doctor` は削除・上書き・再移動を行わず、「アップデートによって再生成された」とか「2つのコピーが同一である」とは断定しません。手動で移動した項目は MacBay の履歴がないためローカルデータ検査の対象外であり、その範囲は `notes` に明記されます。

**結果グループ**: `Healthy`、`Needs attention`、`Unable to verify`、および MacBay が作成していないリンクの `unmanaged` 情報。すべての問題には `--json` 出力で安定した診断コードと推奨される次の操作が付与されます。

**終了コード**: 正常 `0`、問題または検証不能 `1`、診断自体の失敗 `2`。

> [!IMPORTANT]
> `doctor` は読み取り専用です。削除・移動・修復は行わず、内蔵ディスクに別途記録を保存しないため、取り外した外部ボリュームは再接続するまで検証できません。

### 保存されたアプリパスの検査（`references`）

特定の設定ファイルに保存されたアプリパスを検査します。`--path` で指定したファイルのみを読み取り、ディスク上の他の場所は走査しません：

```sh
# ファイルを1つ検査
mb references --path ~/.cursor/mcp.json

# 複数ファイルを検査（繰り返し可能）
mb references --path ~/.cursor/mcp.json --path ~/Library/LaunchAgents/com.example.tool.plist
```

JSON と XML／バイナリ plist は Foundation で読み、TOML・YAML・INI・シェルなどのテキストからは `.app` 境界を含む絶対パスを抽出します。相対パスはカレントディレクトリ、`~` はホーム基準で、重複指定したパスは1回だけ検査します。保存されたパスが存在するかの確認と代替候補の探索のため `/Applications` と `~/Applications` を参照します。ボリュームやマニフェストの検査は行いません。

保存されたパスが無い場合、`/Applications` と `~/Applications` で同名アプリを探します（同じ実体なら `/Applications` を優先）。同じ内部パスがあれば `external_reference_stale_candidate` と現在の候補を報告し、対応アプリや内部ファイルが無ければ `external_reference_missing` です。アクセスエラー・循環リンク・同名アプリの曖昧さは `external_reference_unverified`、読み取り上限は `external_reference_scan_incomplete` です。

> [!NOTE]
> 参照検査は読み取り専用です。パスらしい文字列のヒューリスティック抽出は対応範囲であり、MacBay はシェル変数を展開したりスクリプトを実行したりせず、設定があることだけで現在使われているとは断定しません。既知の MCP 領域（TOML の `mcp_servers`、JSON の `mcpServers`）では無効化されたサーバーを除外し、未対応の TOML 構文は部分検査として報告します。報告されたパスは候補にすぎず、アプリが移動・削除されたことや同一バージョンであること、その設定が現在使われているかは確定しません。パスのワイルドカード、`<AppName>` のようなテンプレートトークン、文字通りの `AppName.app` プレースホルダーはファイル参照として検査せず、該当した項目は findings から除外して `notes` で説明します。外部ボリューム未接続は考えられる原因として案内するだけです。保存されたパスが誤っているようなら、その設定が現在使われているかを先に確認してからファイルをバックアップしてパスを修正してください（例: `/Applications/<App>.app/...`）。MacBay はこれらのファイルを変更しません。

> [!NOTE]
> 上限は設定ファイル 10,000、ファイルあたり 2 MiB、合計読み取り 64 MiB です。バックアップファイルは除外します。

**終了コード**: 保存されたパスがすべて正常なら `0`、欠落パス・読み取り失敗・読み取り不足があれば `1`、引数が不正または検査自体が失敗したら `2`。

### アプリケーションの外部化（`dock`）

アプリケーションバンドルを外部ボリュームに移動し、元の `/Applications/<App>.app` にシンボリックリンクを作成します。

```sh
# まずは --dry-run でプレビューすることをおすすめします
mb dock Example.app --dry-run

# 外部化を実行
mb dock Example.app
```

プレビュー出力例:
```text
Dry run: dock Example.app
  Size: 21.6 GB
  Source: /Applications/Example.app
  Destination: /Volumes/ExternalSSD/MacBay/Applications/Example.app
  Space: destination free 859.5 GB on /Volumes/ExternalSSD
  Space: estimated free after copy 837.9 GB
  Space: estimated internal space freed 21.6 GB (logical size estimate; APFS shared blocks and snapshots can change the actual amount)
  Dry run: no files were changed
```

プレビューでは、移動先ボリュームの空き容量、コピー後の推定空き容量、内蔵ディスクで確保されると見込まれる容量、移動先が不足している場合の不足量も表示します。これらは論理ファイルサイズに基づく保守的な推定値であり、APFSの共有ブロックやスナップショットにより実際の確保量は変わり得ます。実行時には空き容量を再確認し、不足している場合や確認できない場合はコピー前に中止します。容量が十分という推定は移行の成功を保証しません。

**動作の仕組み**:
1. **事前検証**: バンドルの整合性、実行中プロセス（`lsof`）、SQLiteロックファイル（`-wal`, `-shm`）をチェックします。
2. **互換性検査**: コード署名のエンタイトルメントや自己移動マーカーを検証します。
3. **アトミックコピーと検証**: `ditto` を使用してメタデータを保持したままバンドルをコピーし、`codesign --verify --deep --strict` で整合性を検証します。
4. **シンボリックリンクの置換**: 元のバンドルをアトミックにシンボリックリンクへ置き換えます。
5. **システムの更新**: アイコンが汎用の白アイコンになるのを防ぐため、LaunchServicesの登録を再構築（`lsregister -f`）し、Dockを再起動します。

> [!NOTE]
> アプリケーションが ⚠️ **Review**（JSONの `POPUP_RISK`）と判定されている場合は、潜在的なリスクを確認した上で `--force` オプションを指定して実行してください:
> ```sh
> mb dock HeavyStudio.app --force --dry-run
> ```

> [!TIP]
> `/Applications` 内のアプリケーションがすでにMacBay外部で外部ストレージへ接続されているシンボリックリンクである場合、`mb dock` はこれを検知し、代わりに `mb adopt` コマンドを使用するよう案内します。

### アプリケーションの復元（`undock`）

外部化したアプリケーションを元の `/Applications` の場所へ復元し、外部ボリューム上のコピーを削除します:

```sh
# 復元のプレビュー
mb undock Example.app --dry-run

# 内蔵ディスクへの復元を実行
mb undock Example.app
```

復元時も必要な容量をプレビューします: 内蔵ボリュームの空き容量、コピー後の推定空き容量、不足量です。実行時には内蔵ボリュームを再確認し、容量が不足している場合や確認できない場合はコピー前に中止します。

### 外部アプリケーションの管理取り込み（`adopt`）

すでに外部ストレージに配置されているアプリケーションを内蔵ディスクへ復元することなく、MacBay標準配置（`<Volume>/MacBay/Applications/<App>.app`）へと再配置し、`/Applications/<App>.app` シンボリックリンクを更新して `manifest.json` に正式な管理対象として登録します:

```sh
# まずは --dry-run でプレビュー
mb adopt ChatGPT.app --volume /Volumes/ExternalSSD --dry-run

# 管理取り込みを実行
mb adopt ChatGPT.app --volume /Volumes/ExternalSSD
```

プレビュー出力例:
```text
Dry run: adopt ChatGPT.app
  Size: 120.5 MB
  Source: /Volumes/ExternalSSD/Applications/ChatGPT.app
  Destination: /Volumes/ExternalSSD/MacBay/Applications/ChatGPT.app
  Symlink: /Applications/ChatGPT.app -> /Volumes/ExternalSSD/MacBay/Applications/ChatGPT.app
  Space: no additional space required (same volume relocation)
  Dry run: no files were changed
```

**動作の仕組み**:
1. **リンク先の解決**: `/Applications/<App>.app` のシンボリックリンクを追跡し、外部APFSボリューム上の実際のアプリケーションバンドルの位置を特定します。
2. **安全性と互換性の検証**: 実行中プロセス（`lsof`）、SQLiteロックファイル（`-wal`, `-shm`）、コード署名の整合性、移行不可シグナルを検査します。⚠️ **Review**（`POPUP_RISK`）と判定されたアプリには `--force` が必要です。
3. **ジャーナリングとクラッシュ復旧**: 外部ボリューム上に操作ジャーナル（`.operations/adopt-<id>.json`）を記録します。中断された操作は `mb doctor` により未完了操作（`incomplete_operation`）として報告されます。
4. **アトミック再配置**: 同一APFSボリューム内でバンドルを標準パスへアトミックに移動します（すでに標準パスにある場合は移動をスキップ）。
5. **シンボリックリンクのアトミック更新**: `/Applications/<App>.app` のシンボリックリンクを新しい標準パスへアトミックに差し替えます。
6. **マニフェスト登録**: プロセス間ファイルロック（`flock`）のもとで `MacBay/manifest.json` に記録します。
7. **システムの更新**: LaunchServicesの登録情報（`lsregister -f`）を再構築し、Dockを再起動します。

### 重複アプリケーションの比較と修復（`repair`）

`mb doctor` において、マニフェストに登録されたアプリの内蔵パス（`/Applications`）に実体バンドルが再生成され、かつ外部コピーも残存している状態（`local_data_detected`）が検出された場合、`mb repair` を使用して安全に比較・修復を行うことができます:

```sh
# 1. 読み取り専用の比較（バージョン、ビルド、識別子、署名、サイズ）
mb repair "Kiro CLI.app"

# 2. 内蔵アプリの外部再配置（redock）プレビュー
mb repair "Kiro CLI.app" --action redock --dry-run

# 3. 内蔵アプリの保持と管理解除（keep-local）プレビュー
mb repair "Kiro CLI.app" --action keep-local --dry-run

# 4. 実際の実行
mb repair "Kiro CLI.app" --action redock
mb repair "Kiro CLI.app" --action keep-local

# 5. 中断された修復操作のロールバック復元
mb repair "Kiro CLI.app" --rollback
```

**比較出力の例**:
```text
Repair comparison · Kiro CLI.app
  Volume: /Volumes/ExternalSSD

Attributes               Local (/Applications)               External (MacBay)
───────────────────────  ──────────────────────────────────  ──────────────────────────────────
Identifier               com.kiro.cli                        com.kiro.cli
Version                  1.2.0                               1.1.0
Build                    120                                 110
Size                     105.4 MB                            98.2 MB
Signature                Valid                               Valid
Compatibility            Safe                                Safe

Available actions:
  • mb repair "Kiro CLI.app" --action redock
    Re-dock local app to external storage; backs up existing external copy
  • mb repair "Kiro CLI.app" --action keep-local
    Keep local app and remove migration record; external copy remains as unmanaged archive
```

**安全性とバックアップポリシー**:
- **識別子の一致検証**: `redock` は両パスのバンドル識別子（`CFBundleIdentifier`）が一致していることを厳密に検証します。異なるアプリを誤って上書きすることを防止します。
- **既存外部コピーのバックアップ保持**: `redock` の実行時、既存の外部アプリは `<Volume>/MacBay/Backups/<OperationID>/<App>.app` へ安全に退避された後に新しいアプリが配置されます。退避されたバックアップは自動削除されず、永続的に保持されます。
- **独立した修復ジャーナル**: 操作状態は外部ボリュームの `<Volume>/MacBay/.operations/repair-<App>.json`（スキーマ v1）に記録されます。万が一処理が中断された場合、`mb doctor` が未完了操作（`incomplete_operation`）として検知し、`mb repair "<App>" --rollback` による復旧を案内します。
- **内蔵保持（keep-local）**: `keep-local` はマニフェストから該当項目の記録のみをアトミックに削除します。内蔵アプリおよび外部コピーの双方がファイルシステム上にそのまま保持され、外部コピーは非管理アーカイブとなります。

### 任意ディレクトリの外部化（`move` / `unmove`）

ゲームライブラリ、VMディスク、データセット、メディアフォルダなど、あらゆるディレクトリを外部ボリュームの `<Volume>/MacBay/Data/<name>` へ移動し、元の場所をシンボリックリンクに置き換えます。項目は `manifest.json` に `directory` 種別で記録され、`mb status`、`mb doctor`、`mb teardown` がすべて認識します:

```sh
# 移動のプレビュー
mb move ~/Games --dry-run

# 任意のディレクトリを移動
mb move ~/Games

# 内蔵ストレージへ復元（プレビュー/実行）
mb unmove ~/Games --dry-run
mb unmove ~/Games
```

**動作の流れ**:
1. **検証**: シンボリックリンク、非ディレクトリ、`.app` バンドル（`mb dock` を使用）、保護されたシステムパス（`/System`、`/Library`、`/usr`、`/Applications`、`/Volumes`、ホームルート、`~/Library` など）、非内蔵ボリューム上のソース、および `mb cache` が管理するパスを拒否します。`~/Library` 内では `Containers`、`Group Containers`、`Mobile Documents`、`Keychains`、`Mail`、`Preferences`、`Developer` などの共有/システム系サブツリーは移動不可で、`~/.ssh`、`~/.gnupg`、`~/.cargo`、`~/.rustup` などのクレデンシャル領域も禁止です。`Application Support` と `Caches` のルート自体はブロックされますが、その子ディレクトリは移動可能です（例: `~/Library/Application Support/Steam`）。
2. **安全性**: 実行中プロセス（`lsof`）と SQLite ロックを確認し、ディレクトリサイズを測定し、外部ボリュームの空き容量を予測します。
3. **コピーとリンク**: `ditto` で進捗サンプリング付きコピー後、ソースをシンボリックリンクへアトミックに置き換えます。
4. **マニフェスト**: `<Volume>/MacBay/manifest.json` に移動を記録し、`mb unmove` や `mb teardown` で復元できるようにします。

`unmove` はシンボリックリンクを解決し、外部コピーを内蔵へコピーバックし、リンクと外部コピーを削除してマニフェスト記録を外します。記録のある項目はマニフェスト経由で復元され、記録なしに MacBay ストレージを指すリンクは標準 `MacBay/Data/` レイアウト配下のみ復元され、それ以外を指すリンクは拒否されます。

> [!NOTE]
> `mb move` には `mb dock` のような移動後もアプリが動作する仕組み（署名検証、LaunchServices 更新、Dock 再起動）はありません。`.app` バンドルには `dock` を使ってください。

### Xcodeのメンテナンス（`xcode`）

`~/Library/Developer/Xcode/iOS DeviceSupport` を外部ボリュームへオフロードし、不要になった利用不可のiOSシミュレータをクリーンアップします:

```sh
# Xcode外部化のプレビュー
mb xcode --dry-run

# Xcodeメンテナンスを実行
mb xcode
```

> [!TIP]
> 既に外部ボリュームを指すシンボリックリンク（例: `/Volumes/<Drive>/Developer/Xcode/iOS DeviceSupport`）が存在する場合、MacBayは不要な再移動を行わず、リンク先を正しく認識して検証します。

### 開発者キャッシュのルーティング（`cache`）

`~/.zshrc` に安全に管理・分離された設定ブロックを追加することで、開発ツールのパッケージキャッシュを外部ストレージへルーティングします:

```sh
# キャッシュリダイレクトのプレビュー
mb cache --enable --dry-run

# 外部キャッシュルーティングを有効化
mb cache --enable

# ~/.zshrc から管理ブロックを削除してリセット
mb cache --reset
```

管理対象のキャッシュ:
- `npm`: `npm_config_cache`
- `pnpm store`: `npm_config_store_dir`
- `Yarn Berry キャッシュ`（`~/.yarn/berry/cache`）: シンボリックリンクのみ — グローバルキャッシュが有効な既定設定では Berry は `YARN_CACHE_FOLDER` を無視し、さらにこの変数は zero-install リポジトリが使うプロジェクトの `cacheFolder` 設定まで上書きしてしまうためです
- `Yarn v1 キャッシュ`（`~/Library/Caches/Yarn`）: 同じ理由でシンボリックリンクのみ
- `bun キャッシュ`: `BUN_INSTALL_CACHE_DIR`
- `uv`: `UV_CACHE_DIR`
- `pip`: `PIP_CACHE_DIR`
- `Gradle`: `GRADLE_USER_HOME`
- `CocoaPods`: `CP_HOME_DIR`
- `Go モジュール`: `GOMODCACHE`
- `Android ユーザーデータ`: `ANDROID_USER_HOME`
- `Homebrew ダウンロード`: `HOMEBREW_CACHE`
- `Hugging Face`: `HF_HOME`

> [!NOTE]
> Cargo（`~/.cargo`）は意図的にルーティングしません。`CARGO_HOME` には `~/.cargo/bin` の rustup shim も含まれるため、移動するとドライブ切断時に `cargo`/`rustup` が壊れます。大きなプロジェクトディレクトリは `mb move` で移動してください。

### 一括クリーンアップ（`teardown`）

MacBayが管理するすべてを一括で元に戻します——アンインストール前や別の外部ドライブへの移行時に便利です:

```sh
# teardown全体をプレビュー
mb teardown --dry-run

# 全管理アイテムを復元し設定をリセット
mb teardown

# 単一ボリュームに限定
mb teardown --volume /Volumes/ExternalSSD
```

**実行内容**:
1. **記録の復元**: 接続中の各適格ボリューム（または `--volume`）について、マニフェストの全項目を復元します——アプリは `undock`、移動済みディレクトリは `unmove` 経路で。
2. **既知リンクの掃除**: マニフェスト記録なしにシンボリックリンクのまま残っている開発者向けパス（Xcode対象・キャッシュ対象）を整理します。`MacBay/Caches/` 配下のリンクは削除して空ディレクトリを再作成（外部コピーは非管理アーカイブとして保持）、その他の `MacBay/` ルート配下のリンクは内蔵へ完全復元します。
3. **設定のリセット**: 失敗のない *完全な* teardown（`--volume` 省略）のときのみ、`~/.zshrc` の管理ブロックを削除し保存済みデフォルトボリュームを忘れます。デフォルトボリュームは実際に今回の teardown 対象だった場合のみ忘却され、未マウントのボリュームは note とともに保持され後でデータへ再アクセスできます。対象範囲外のボリューム上の MacBay ディレクトリを指すキャッシュリンクは、黙ってスキップせずスキップした旨を報告します。
4. **レポート**: 項目ごとの失敗は中断せず収集され、失敗があれば終了コードは `1` になります。各ボリュームの `MacBay/` ディレクトリ自体は残します——バックアップや未記録データは決して削除しません——残存ディレクトリはレポートのnotesで案内します。

> [!IMPORTANT]
> `teardown` はデータを内蔵ディスクへコピーバックします。内蔵容量が不足する項目はエラーで停止するため、まず `mb teardown --dry-run` で内容を確認してください。

---

## 外部ボリュームの要件と制限

データの整合性を保証するため、MacBayは厳格なボリューム適合基準を設けています:

| 要件項目 | ルール | 理由 |
| :--- | :--- | :--- |
| **マウントポイント** | `/Volumes/` 配下にマウントされていること | macOS標準の外部ボリューム階層であるため |
| **ドライブ種別** | 物理的な外部ドライブ（`Internal == false`） | プライマリ（内蔵）ドライブへの逆外部化を防ぐため |
| **ファイルシステム** | **APFS**（`FilesystemType == apfs`） | APFSのクローン／シンボリックリンク／メタデータ機能が必要なため |
| **アクセス権限** | 書き込み可能（`WritableVolume == true`） | 読み取り専用ドライブにはアプリケーションバンドルを配置できないため |
| **プロトコル** | `BusProtocol != "Disk Image"` | 一時的なインストーラーDMGを自動的に除外するため |

- **選択の優先順位**: `--volume`（または `-v`）が最優先で、次に `mb init` で保存したデフォルト、最後に自動検出です。
- **自動選択**: 適合する外部ボリュームが1つだけマウントされている場合、MacBayが自動的に選択します。
- **複数ボリューム接続時**: 適合するドライブが2台以上接続されている場合、誤ったドライブへの書き込みを防ぐため `--volume <path>`（または `-v`）の指定が必須となります。`mb init` でデフォルトを保存すれば、毎回フラグを付ける必要はありません。
- **保存されたデフォルト**: `mb init` は適合するボリュームを1つ `~/.config/macbay/config.json`（`$XDG_CONFIG_HOME` を尊重）に保存し、デフォルトが利用できないときに別のドライブへ黙って切り替えることはありません。

---

## セキュリティモデルと互換性ティア

バンドルを移行する前に、`AppInspector` がアプリケーションを以下のティアに判定・分類します:

- 🟢 **Safe**（JSONの `SAFE`）: 自己移動フックや仮想化要件を含まない標準的なバンドル構造です。通常の外部化を安全に行えます。
- ⚠️ **Review**（JSONの `POPUP_RISK`）: 自己移動チェック（Mach-OやASAR内の `moveToApplicationsFolder`、`PFMoveToApplicationsFolder` など）や特権ヘルパーツール（`SMPrivilegedExecutables`）が含まれています。移行するには `-f, --force` フラグが必要です。
- ❌ **Blocked**（JSONの `BLOCKED`）: ハイパーバイザ／仮想化エンタイトルメント（`com.apple.security.virtualization`）を要求する、ドライバ／システム／カーネル拡張機能を含む、あるいはコード署名が破損しているアプリケーションです。**システムの不安定化を防ぐため、移行はブロックされます。**

---

## 外部ストレージ構造

外部化を実行すると、MacBayは外部ドライブ上に以下のディレクトリ構造を保持します:

```text
/Volumes/<ExternalDrive>/MacBay/
├── Applications/       # 外部化されたアプリケーションバンドル
├── Caches/             # npm、uv、Gradleなどの開発者キャッシュ
├── Data/               # `mb move` で移動したディレクトリ
├── Xcode/              # iOS DeviceSupportシンボルキャッシュ
└── manifest.json       # 全ての外部化（dock）アイテムを管理するCodableメタデータマニフェスト
```

---

## JSON出力と自動化

すべてのコマンドで `--json` フラグをサポートしており、スクリプト、CI、エージェントツールとの連携が容易です:

```sh
mb status --json
```

`mb doctor --json` は `volumes`、`findings`、`summary`、`warnings`、`notes` を出力します。各項目には安定した `code`（例: `link_target_unavailable`、`link_unmanaged`、`local_data_detected`、`record_source_missing`、`manifest_unreadable`）、`status`（`healthy`、`needs_attention`、`unable_to_verify`）、関連パス、該当する場合はサイズ、推奨される次の操作が含まれます。

`mb references --json` は `generatedAt`、`findings`、`notes` を出力します。各項目には安定した `code`（例: `external_reference_stale_candidate`、`external_reference_missing`、`external_reference_unverified`、`external_reference_scan_incomplete`、`external_config_unreadable`、`external_config_partially_checked`）、`status`、元ファイル、保存されたパス、確認済みの候補（ある場合）、任意の `referenceLocations`、推奨される次の操作が含まれます。

エラー発生時、MacBayは構造化されたエラーエンベロープを `stderr` に出力し、非ゼロのステータスコードで終了します:

```json
{
  "error": {
    "code": "configuration_error | retryable_error | execution_error",
    "message": "Application is blocked from migration (/Applications/VirtualMachine.app)",
    "details": "com.apple.security.virtualization=true in codesign entitlements"
  }
}
```

---

## コントリビューション

コントリビューションを心より歓迎します！ 行動規範、ハードウェア不要のテスト環境構築、プルリクエストの提出手順についての詳細は [CONTRIBUTING.md](../CONTRIBUTING.md) をご覧ください。

---

## ライセンス

MacBayは [MITライセンス](../LICENSE) の下で公開されているオープンソースソフトウェアです。 Copyright © 2026 thingk0.
