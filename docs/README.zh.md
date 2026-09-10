<p align="center">
  <img src="../Assets/macbay-icon-concept.png" width="140" alt="MacBay logo">
</p>

<h1 align="center">MacBay</h1>

<p align="center">
  <a href="../README.md">English</a> •
  <a href="README.ko.md">한국어</a> •
  <a href="README.zh.md">简体中文</a> •
  <a href="README.ja.md">日本語</a>
</p>

MacBay 是一款专为 Apple Silicon Mac 设计的开发者优先存储外部化工具。它能够安全地将大型应用程序、Xcode DeviceSupport 数据以及各类开发者缓存迁移至外置 APFS 驱动器，同时无缝保持终端命令行工具（CLI）、LaunchAgent 和 macOS Dock 栏原有的访问路径不变。

[![CI](https://github.com/thingk0/macbay/actions/workflows/ci.yml/badge.svg)](https://github.com/thingk0/macbay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-orange.svg)](https://en.wikipedia.org/wiki/Apple_silicon)

---

## 特性

- **应用程序迁移 (`dock` / `undock`)**：将大型应用迁移至外置存储并替换为符号链接。自动刷新 Dock 栏图标与 LaunchServices 注册。
- **安全检查引擎 (`AppInspector`)**：自动分析应用程序包（App Bundle）的虚拟化权限（Entitlements）、内核/系统扩展（KEXT/System Extensions）以及硬编码重定位信号。
- **Xcode DeviceSupport 管理 (`xcode`)**：迁移庞大的 iOS DeviceSupport 符号文件，同时确保 Xcode 无缝正常运行。保留原有的历史链接，并清理不可用的模拟器。
- **开发者缓存重定向 (`cache`)**：通过在 `~/.zshrc` 中注入清晰、隔离的配置块，将 npm、uv、Gradle 和 Hugging Face 的缓存路由至外置存储。
- **严格的外置卷验证**：自动校验外置 APFS 文件系统，拒绝安装器 DMG、只读驱动器及内置磁盘。

---

## 支持环境

- **macOS**：13 (Ventura) 或更高版本
- **硬件架构**：Apple Silicon (M1 / M2 / M3 / M4)
- **外置存储**：格式化为 **APFS** 的物理外置固态硬盘/机械硬盘（GUID 分区图，支持写入）
- **开发工具**：Xcode 命令行工具（Command Line Tools，`xcode-select --install`）

---

## 安装方式

### 方式 1：Homebrew（推荐）

使用 Homebrew 安装 MacBay：

```sh
brew install thingk0/tap/macbay
mb --help
```

Homebrew 将直接基于带有标签（Tag）的源码版本针对 Apple Silicon（macOS 13+）编译二进制文件。`mb` 命令及其别名 `macbay` 均会被安装到 Homebrew 的 `bin` 目录下。

#### 通过 Homebrew 更新

```sh
brew update
brew upgrade macbay
```

#### 通过 Homebrew 卸载

> [!CAUTION]
> `brew uninstall macbay` 仅会删除 CLI 可执行文件（`mb` 和 `macbay`）。它**不会**自动从外置存储中恢复已迁移的应用程序，也不会重置 `~/.zshrc` 中的缓存重定向配置。
>
> **在卸载 MacBay 之前**，请务必执行以下清理步骤：
> 1. 将所有已外置的应用恢复回内置存储：
>    ```sh
>    mb undock <AppName>.app
>    ```
> 2. 重置 `~/.zshrc` 中的缓存环境变量：
>    ```sh
>    mb cache --reset
>    ```
> 3. 随后即可安全卸载 Formula：
>    ```sh
>    brew uninstall macbay
>    ```

---

### 方式 2：源码构建

环境要求：macOS 13 或更高版本、Apple Silicon 芯片，以及 Xcode 命令行工具或 Xcode 15.3+（提供 Swift 5.10 或更高版本）。

```sh
# 克隆仓库
git clone https://github.com/thingk0/macbay.git
cd macbay

# 构建 Release 二进制文件
swift build -c release

# 运行测试
swift test

# 复制到 /usr/local/bin（可选）
sudo cp .build/release/mb /usr/local/bin/mb
sudo ln -sf /usr/local/bin/mb /usr/local/bin/macbay
```

验证安装：

```sh
mb --version
# 输出：1.0.0
```

---

## 快速入门

### 1. 检查存储状态

查看内置磁盘剩余空间、已挂载的外置卷以及所有不合规的驱动器：

```sh
mb status
```

输出示例：
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

### 2. 发现可迁移目标

扫描大型应用程序、开发者缓存、已外部化应用程序以及断开的符号链接：

```sh
mb scan
```

输出示例：
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

若需查看完整应用路径及详细兼容性评估原因与证据：
```sh
mb scan --verbose
```

- **候选应用 (Applications)**: 位于内置磁盘的大型应用（≥ 200 MB）及兼容性等级（`Safe`、`Review`、`Blocked`）。
- **开发者缓存 (Developer caches)**: 大型开发工具缓存（如 CoreSimulator、npm cache）。
- **已外部化应用 (Already external)**: 已重定向至外置存储的应用程序：
  - `MacBay`: 已登记在外置卷的 `manifest.json` 中并由 MacBay 管理。
  - `Unmanaged`: 手动迁移或通过其他工具迁移、MacBay 中无记录的应用。
  - `Unconfirmed`: 目标位于外置卷，但读取清单文件时出错。
- **未解析链接 (Unresolved links)**: 目标不存在（`Target unavailable`）、循环链接或卷检查失败等异常链接。

### 3. 链接与记录诊断

检查应用程序链接、开发者缓存链接，以及已连接卷中的 MacBay 记录是否与实际情况一致。`doctor` 为只读命令，不会修改任何文件：

```sh
mb doctor
```

输出示例：
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

- `Healthy`：链接可正常解析，且与 MacBay 记录或既有目录结构一致。无记录的链接会作为 `unmanaged` 信息展示，而非问题。
- `Needs attention`：链接断开、循环链接、实际目标与记录路径不一致，或记录中的外置副本已丢失。
- `Unable to verify`：无法读取链接、链接所在卷或该卷的 `manifest.json`（例如权限错误或清单文件损坏）。
- `Nothing to verify`（没有可检查的记录或链接）会与“未发现问题”分开报告。

退出码：无异常 `0`，发现问题或存在无法验证项 `1`，诊断本身执行失败（例如 `--volume` 路径无法检查）`2`。

> [!NOTE]
> MacBay 只读取已连接外置卷中的记录，因此无法验证已断开的驱动器。诊断只报告实际检查到的范围，不会假设目标丢失是由于磁盘拔出或数据删除。

---

## 命令与用法

### 链接与记录诊断 (`doctor`)

检查 `/Applications` 中的链接、已知的开发者缓存链接，以及已连接外置卷（含只读卷）中的 MacBay 记录。该命令不会修改任何文件或配置：

```sh
# 诊断已连接的卷与本地链接
mb doctor

# 额外检查未挂载在 /Volumes 下的卷
mb doctor --volume /Volumes/Archive
```

**检查内容**：
1. **应用程序链接**：解析 `/Applications` 中的所有符号链接（包括相对链接、链式链接与循环链接）。
2. **开发者缓存链接**：`~/Library/Developer/Xcode/iOS DeviceSupport`、`~/Library/Developer/CoreSimulator`、`~/.npm`、`~/.cache/uv`、`~/.gradle` 与 `~/.cache/huggingface`。
3. **卷记录**：将已连接卷的 `MacBay/manifest.json` 与实际源路径和目标路径进行比对。
4. **记录副本**：若源路径已不再是链接且外置副本也已丢失，则报告为记录与实际状态不一致。

**结果分组**：`Healthy`、`Needs attention`、`Unable to verify`，以及针对非 MacBay 创建的链接的 `unmanaged` 信息。所有问题在 `--json` 输出中都会附带稳定的诊断代码与建议操作。

**退出码**：健康 `0`，发现问题或存在无法验证项 `1`，诊断本身失败 `2`。

> [!IMPORTANT]
> `doctor` 为只读命令：它不会删除、移动或修复任何内容，也不会在内置磁盘中保存额外记录，因此断开的外置卷在重新连接之前无法被验证。

### 迁移应用程序 (`dock`)

将应用程序包迁移到外置卷，并在 `/Applications/<App>.app` 创建指向该卷的符号链接。

```sh
# 建议先使用 --dry-run 进行演练预览
mb dock Example.app --dry-run

# 执行迁移
mb dock Example.app
```

**工作流程**：
1. **预检验证**：检查应用程序包完整性、活跃进程（`lsof`）和 SQLite 锁（`-wal`、`-shm`）。
2. **兼容性检查**：分析代码签名授权（Entitlements）和重定位特征标记。
3. **原子拷贝与校验**：通过 `ditto` 拷贝应用包，保留全部元数据，并通过 `codesign --verify --deep --strict` 进行深度校验。
4. **符号链接替换**：以原子操作将原始应用包替换为符号链接。
5. **系统刷新**：重建 LaunchServices 注册数据库（`lsregister -f`）并重启 Dock，防止应用图标变为通用的白色占位图标。

> [!NOTE]
> 如果应用程序被标记为 ⚠️ **Review**（JSON 中的 `POPUP_RISK`），在评估潜在风险后可传入 `--force` 参数强制继续：
> ```sh
> mb dock HeavyStudio.app --force --dry-run
> ```

### 恢复应用程序 (`undock`)

将已外置的应用程序恢复到 `/Applications` 下的原始位置，并清理外置磁盘上的副本：

```sh
# 预览恢复操作
mb undock Example.app --dry-run

# 恢复至内置磁盘
mb undock Example.app
```

### Xcode 维护管理 (`xcode`)

将 `~/Library/Developer/Xcode/iOS DeviceSupport` 外置到外部卷，并清理不可用的 iOS 模拟器：

```sh
# 预览 Xcode 外置操作
mb xcode --dry-run

# 执行 Xcode 维护操作
mb xcode
```

> [!TIP]
> 如果您已经存在指向外置卷的符号链接（例如 `/Volumes/<Drive>/Developer/Xcode/iOS DeviceSupport`），MacBay 会自动识别并验证该链接目标，避免进行不必要的重复迁移。

### 开发者缓存重定向 (`cache`)

通过在 `~/.zshrc` 中添加托管且隔离的配置块，将开发者包管理缓存重定向至外置存储：

```sh
# 预览缓存重定向
mb cache --enable --dry-run

# 启用外置缓存重定向
mb cache --enable

# 重置并从 ~/.zshrc 中移除托管配置块
mb cache --reset
```

支持托管的缓存包括：
- `npm`：`npm_config_cache`
- `uv`：`UV_CACHE_DIR`
- `Gradle`：`GRADLE_USER_HOME`
- `Hugging Face`：`HF_HOME`

---

## 外置卷要求与限制

为确保数据完整性与系统稳定性，MacBay 对外置卷实施了严格的准入标准：

| 要求项 | 规则 | 原理与说明 |
| :--- | :--- | :--- |
| **挂载点** | 必须挂载在 `/Volumes/` 目录下 | 标准 macOS 外置卷层级结构 |
| **驱动器类型** | 物理外置设备 (`Internal == false`) | 避免误迁移回系统主磁盘 |
| **文件系统** | **APFS** (`FilesystemType == apfs`) | 依赖 APFS 克隆、符号链接与元数据扩展能力 |
| **权限** | 支持写入 (`WritableVolume == true`) | 只读驱动器无法承载应用程序包 |
| **总线协议** | `BusProtocol != "Disk Image"` | 自动拒绝临时安装器 DMG 磁盘映像 |

- **自动选择**：当仅挂载了一个符合条件的外置卷时，MacBay 会自动选择该卷。
- **多卷环境**：当连接了两个或更多符合条件的驱动器时，必须使用 `--volume <path>`（或 `-v`）显式指定目标卷，以防止误写入其他驱动器。

---

## 安全模型与兼容性分级

在迁移任何应用包之前，`AppInspector` 都会对该应用程序进行等级评估：

- 🟢 **Safe**（JSON 中的 `SAFE`）：应用包结构规范，无自我重定位钩子或虚拟化依赖。可安全进行常规迁移。
- ⚠️ **Review**（JSON 中的 `POPUP_RISK`）：应用程序包含自我重定位检测（例如在 Mach-O/ASAR 中调用 `moveToApplicationsFolder`、`PFMoveToApplicationsFolder`）或特权辅助工具（`SMPrivilegedExecutables`）。需要传入 `-f, --force` 参数才可迁移。
- ❌ **Blocked**（JSON 中的 `BLOCKED`）：应用程序需要虚拟化/虚拟机管理权限（`com.apple.security.virtualization`）、包含驱动程序/系统/内核扩展（Driver/System/Kernel Extensions），或代码签名损坏。**禁止迁移此类应用，以防引发系统不稳定。**

---

## 外置目录结构

执行外部化操作时，MacBay 会在外置驱动器中维护以下规范的目录结构：

```text
/Volumes/<ExternalDrive>/MacBay/
├── Applications/       # 已迁移的应用程序包
├── Caches/             # npm、uv、Gradle 和 Hugging Face 缓存
├── Xcode/              # iOS DeviceSupport 符号缓存
└── manifest.json       # 记录所有已外置项元数据的 Codable 清单文件
```

---

## JSON 输出与自动化

所有命令均支持 `--json` 参数，便于与自动化脚本、CI/CD 流程及智能体（Agent）工具深度集成：

```sh
mb status --json
```

`mb doctor --json` 会输出 `volumes`、`findings` 与 `summary`。每个条目都带有稳定的 `code`（例如 `link_target_unavailable`、`link_unmanaged`、`manifest_unreadable`）、`status`（`healthy`、`needs_attention`、`unable_to_verify`）、相关路径以及建议操作。

当发生错误时，MacBay 会向 `stderr` 输出结构化的错误信封（Envelope）并以非零状态码退出：

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

## 参与贡献

欢迎社区贡献！请参阅 [CONTRIBUTING.md](../CONTRIBUTING.md) 了解我们的行为准则、无需物理硬件的测试方案以及 Pull Request 提交规范。

---

## 开源许可证

MacBay 遵循 [MIT 许可证](../LICENSE) 开源。Copyright © 2026 thingk0。
