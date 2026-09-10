<p align="center">
  <img src="Assets/macbay-icon-concept.png" width="140" alt="MacBay logo">
</p>

<h1 align="center">MacBay</h1>

<p align="center">
  <a href="README.md">English</a> •
  <a href="README.ko.md">한국어</a> •
  <a href="README.zh.md">简体中文</a> •
  <a href="README.ja.md">日本語</a>
</p>

MacBayは、Apple Silicon Mac向けに設計された開発者ファーストなストレージ外部化ツールです。大容量アプリケーション、Xcode DeviceSupportデータ、各種開発者キャッシュを外部APFSドライブへ安全に移行しながら、ターミナルCLI、LaunchAgent、macOS Dock向けに元のパスを透過的に維持します。

[![CI](https://github.com/thingk0/macbay/actions/workflows/ci.yml/badge.svg)](https://github.com/thingk0/macbay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-orange.svg)](https://en.wikipedia.org/wiki/Apple_silicon)

---

## 主な機能

- **アプリケーションの外部化（`dock` / `undock`）**: 大容量アプリを外部ストレージへ移行し、元の位置にシンボリックリンクを作成します。DockアイコンやLaunchServicesの登録も自動的に更新されます。
- **安全性判定エンジン（`AppInspector`）**: アプリケーションバンドルを自動検査し、仮想化エンタイトルメント、カーネル／システム拡張機能、ハードコードされた自己移動シグナルを検出します。
- **Xcode DeviceSupportの管理（`xcode`）**: Xcodeの正常な動作を維持したまま、肥大化しやすいiOS DeviceSupportシンボルを外部ストレージへオフロードします。既存のレガシーリンクを保持し、利用不可となったシミュレータのクリーンアップも行います。
- **開発者キャッシュのルーティング（`cache`）**: `~/.zshrc` 内に独立した管理ブロックを追加し、npm、uv、Gradle、Hugging Faceのキャッシュを外部ストレージへルーティングします。
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
> **MacBayをアンインストールする前に**、必ず以下のクリーンアップ手順を実行してください:
> 1. 外部化（dock）したアプリケーションを内蔵ストレージへ復元:
>    ```sh
>    mb undock <AppName>.app
>    ```
> 2. `~/.zshrc` のキャッシュ環境変数をリセット:
>    ```sh
>    mb cache --reset
>    ```
> 3. クリーンアップ完了後、Formulaを安全にアンインストール:
>    ```sh
>    brew uninstall macbay
>    ```

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
# 出力例: 1.0.0
```

---

## クイックスタート

### 1. ストレージ状態の確認

内蔵ドライブの空き容量、マウントされている外部ボリューム、および移行対象外のドライブを確認します:

```sh
mb status
```

### 2. 外部化候補の検出

大容量アプリケーションや開発者キャッシュをスキャンし、それぞれの安全性評価を確認します:

```sh
mb scan
```

出力例:
```text
MacBay scan
Threshold: 200.0 MB
Candidates: 8
  • [app] 🟢 SAFE Aside.app — 2.0 GB (/Applications/Aside.app)
  • [app] ⚠️ POPUP_RISK Claude.app — 825.2 MB (/Applications/Claude.app)
  • [app] ❌ BLOCKED OrbStack.app — 694.6 MB (/Applications/OrbStack.app)
  • [cache] CoreSimulator — 191.5 MB (/Users/.../Library/Developer/CoreSimulator)
  • [cache] npm cache — 124.2 MB (/Users/.../.npm)
```

---

## コマンドと使い方

### アプリケーションの外部化（`dock`）

アプリケーションバンドルを外部ボリュームに移動し、元の `/Applications/<App>.app` にシンボリックリンクを作成します。

```sh
# まずは --dry-run でプレビューすることをおすすめします
mb dock Example.app --dry-run

# 外部化を実行
mb dock Example.app
```

**動作の仕組み**:
1. **事前検証**: バンドルの整合性、実行中プロセス（`lsof`）、SQLiteロックファイル（`-wal`, `-shm`）をチェックします。
2. **互換性検査**: コード署名のエンタイトルメントや自己移動マーカーを検証します。
3. **アトミックコピーと検証**: `ditto` を使用してメタデータを保持したままバンドルをコピーし、`codesign --verify --deep --strict` で整合性を検証します。
4. **シンボリックリンクの置換**: 元のバンドルをアトミックにシンボリックリンクへ置き換えます。
5. **システムの更新**: アイコンが汎用の白アイコンになるのを防ぐため、LaunchServicesの登録を再構築（`lsregister -f`）し、Dockを再起動します。

> [!NOTE]
> アプリケーションが ⚠️ **POPUP_RISK** と判定されている場合は、潜在的なリスクを確認した上で `--force` オプションを指定して実行してください:
> ```sh
> mb dock Claude.app --force --dry-run
> ```

### アプリケーションの復元（`undock`）

外部化したアプリケーションを元の `/Applications` の場所へ復元し、外部ボリューム上のコピーを削除します:

```sh
# 復元のプレビュー
mb undock Example.app --dry-run

# 内蔵ディスクへの復元を実行
mb undock Example.app
```

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
- `uv`: `UV_CACHE_DIR`
- `Gradle`: `GRADLE_USER_HOME`
- `Hugging Face`: `HF_HOME`

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

- **自動選択**: 適合する外部ボリュームが1つだけマウントされている場合、MacBayが自動的に選択します。
- **複数ボリューム接続時**: 適合するドライブが2台以上接続されている場合、誤ったドライブへの書き込みを防ぐため `--volume <path>`（または `-v`）の指定が必須となります。

---

## セキュリティモデルと互換性ティア

バンドルを移行する前に、`AppInspector` がアプリケーションを以下のティアに判定・分類します:

- 🟢 **SAFE**: 自己移動フックや仮想化要件を含まない標準的なバンドル構造です。通常の外部化を安全に行えます。
- ⚠️ **POPUP_RISK**: 自己移動チェック（Mach-OやASAR内の `moveToApplicationsFolder`、`PFMoveToApplicationsFolder` など）や特権ヘルパーツール（`SMPrivilegedExecutables`）が含まれています。移行するには `-f, --force` フラグが必要です。
- ❌ **BLOCKED**: ハイパーバイザ／仮想化エンタイトルメント（`com.apple.security.virtualization`）を要求する、ドライバ／システム／カーネル拡張機能を含む、あるいはコード署名が破損しているアプリケーションです。**システムの不安定化を防ぐため、移行はブロックされます。**

---

## 外部ストレージ構造

外部化を実行すると、MacBayは外部ドライブ上に以下のディレクトリ構造を保持します:

```text
/Volumes/<ExternalDrive>/MacBay/
├── Applications/       # 外部化されたアプリケーションバンドル
├── Caches/             # npm、uv、Gradle、Hugging Faceのキャッシュ
├── Xcode/              # iOS DeviceSupportシンボルキャッシュ
└── manifest.json       # 全ての外部化（dock）アイテムを管理するCodableメタデータマニフェスト
```

---

## JSON出力と自動化

すべてのコマンドで `--json` フラグをサポートしており、スクリプト、CI、エージェントツールとの連携が容易です:

```sh
mb status --json
```

エラー発生時、MacBayは構造化されたエラーエンベロープを `stderr` に出力し、非ゼロのステータスコードで終了します:

```json
{
  "error": {
    "code": "configuration_error | retryable_error | execution_error",
    "message": "Application is blocked from migration (/Applications/OrbStack.app)",
    "details": "com.apple.security.virtualization=true in codesign entitlements"
  }
}
```

---

## コントリビューション

コントリビューションを心より歓迎します！ 行動規範、ハードウェア不要のテスト環境構築、プルリクエストの提出手順についての詳細は [CONTRIBUTING.md](CONTRIBUTING.md) をご覧ください。

---

## ライセンス

MacBayは [MITライセンス](LICENSE) の下で公開されているオープンソースソフトウェアです。 Copyright © 2026 thingk0.
