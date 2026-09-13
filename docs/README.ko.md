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

MacBay는 Apple Silicon Mac을 위해 설계된 개발자 중심의 스토리지 외장화 도구입니다. 대용량 애플리케이션, Xcode DeviceSupport 데이터, 개발자 캐시를 외장 APFS 드라이브로 안전하게 이전하면서도 터미널 CLI, LaunchAgent, macOS Dock에서 사용할 수 있도록 기존 경로를 투명하게 유지합니다.

[![CI](https://github.com/thingk0/macbay/actions/workflows/ci.yml/badge.svg)](https://github.com/thingk0/macbay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-orange.svg)](https://en.wikipedia.org/wiki/Apple_silicon)

---

## 주요 기능

- **대화형 TUI 모드 (`mb` / `mb tui`)**: 터미널에서 `mb`만 입력하여 키보드로 조작하는 터미널 UI를 엽니다. 저장 공간 조회, 앱 후보 탐색(Safe/Review/Blocked 상태), dry-run 미리보기 및 안전한 앱 이동·복원, 진단 결과 및 문제별 권장 조치를 탐색할 수 있습니다.
- **애플리케이션 이전 (`dock` / `undock` / `adopt`)**: 대용량 앱을 외장 스토리지로 마이그레이션하거나, 내장 복원 없이 기존 외장 앱을 MacBay 표준 구조로 수용합니다. Dock 아이콘과 LaunchServices 등록 정보가 자동으로 갱신됩니다.
- **무손실 애플리케이션 캐시 정리 (`purge` / `pu`)**: 사용자 계정, SQLite 데이터베이스, 환경 설정을 전혀 건드리지 않고, 자동 재생성되는 Chromium/Electron 캐시(`Code Cache`, `GPUCache`, `CacheStorage`), ShipIt 업데이트 설치 파일, Homebrew 패키지 다운로드 캐시, 진단 크래시 로그를 안전하게 정리하여 내장 SSD 공간을 수 기가바이트 이상 확보합니다.
- **안전성 검사 엔진 (`AppInspector`)**: 앱 번들의 가상화 권한(entitlement), 커널/시스템 확장(KEXT/System Extension), 하드코딩된 자체 재배치 로직 여부를 자동으로 검사합니다.
- **Xcode DeviceSupport 관리 (`xcode`)**: 방대한 용량을 차지하는 iOS DeviceSupport 심볼을 외장 드라이브로 이전하면서도 Xcode가 정상적으로 작동하도록 지원합니다. 기존 레거시 심볼릭 링크를 보존하고 사용 불가능한 시뮬레이터를 정리합니다.
- **임의 디렉터리 이전 (`move` / `unmove`)**: 게임 라이브러리, VM 디스크, 데이터셋, 미디어 폴더 등 어떤 디렉터리든 `<Volume>/MacBay/Data/`로 이전하고, 앱과 동일한 매니페스트 추적 심볼릭 링크 모델로 관리합니다.
- **개발자 캐시 경로 재지정 (`cache`)**: `~/.zshrc` 내에 격리 관리되는 설정 블록을 통해 npm, pnpm, Yarn, bun, uv, pip, Gradle, CocoaPods, Go 모듈, Android 사용자 데이터, Homebrew 다운로드, Hugging Face 캐시 디렉터리를 외장 스토리지로 라우팅합니다.
- **자체 정리 (`teardown`)**: 관리 중인 모든 앱과 디렉터리를 복원하고, 관리 캐시 링크와 `~/.zshrc` 블록을 제거하고, 기본 볼륨을 삭제 전에 한 번의 명령으로 잊습니다.
- **엄격한 볼륨 유효성 검사**: 외장 APFS 파일시스템을 자동으로 검증하며, 설치용 DMG 디스크 이미지, 읽기 전용 드라이브, 내부 디스크는 사전에 제외합니다.

---

## 지원 환경

- **macOS**: 13 (Ventura) 이상
- **하드웨어**: Apple Silicon (M1 / M2 / M3 / M4)
- **외장 스토리지**: **APFS**(GUID 파티션 맵, 쓰기 가능)로 포맷된 물리 외장 SSD/HDD
- **개발자 도구**: Xcode Command Line Tools (`xcode-select --install`)

---

## 설치 방법

### 방법 1: Homebrew (권장)

Homebrew를 사용하여 MacBay를 설치합니다:

```sh
brew install thingk0/tap/macbay
mb --help
```

Homebrew는 Apple Silicon(macOS 13+) 환경에 맞추어 태그된 릴리스 소스로부터 바이너리를 직접 빌드합니다. `mb` 명령과 `macbay` 별칭(alias)이 모두 Homebrew `bin` 디렉터리에 설치됩니다.

#### Homebrew를 통한 업데이트

```sh
brew update
brew upgrade macbay
```

#### Homebrew를 통한 삭제

> [!CAUTION]
> `brew uninstall macbay` 명령은 CLI 실행 파일(`mb` 및 `macbay`)만 삭제합니다. 외장 스토리지로 이전된 애플리케이션을 내부 저장소로 자동 복원하거나 `~/.zshrc`의 캐시 리디렉션 설정을 되돌리지 **않습니다**.
>
> **MacBay를 삭제하기 전에** 한 번의 명령으로 관리 중인 모든 것을 복원하세요:
> 1. teardown을 실행합니다(`--dry-run`으로 먼저 미리보기):
>    ```sh
>    mb teardown --dry-run
>    mb teardown
>    ```
>    dock된 앱과 move된 디렉터리를 복원하고, 관리 캐시 링크를 제거하고, `~/.zshrc` 블록을 지우며, 기본 볼륨을 잊습니다.
> 2. 이제 안전하게 포뮬러를 삭제합니다:
>    ```sh
>    brew uninstall macbay
>    ```
>
> 수동 정리를 선호한다면 dock된 각 앱에 `mb undock <AppName>.app`, move된 각 디렉터리에 `mb unmove <path>`, 그리고 `mb cache --reset`을 대신 실행하세요.

---

### 방법 2: 소스 빌드

요구 사항: macOS 13 이상, Apple Silicon, Xcode Command Line Tools 또는 Xcode 15.3 이상 (Swift 5.10 이상 제공).

```sh
# 저장소 클론
git clone https://github.com/thingk0/macbay.git
cd macbay

# 릴리스 바이너리 빌드
swift build -c release

# 테스트 실행
swift test

# /usr/local/bin으로 복사 (선택 사항)
sudo cp .build/release/mb /usr/local/bin/mb
sudo ln -sf /usr/local/bin/mb /usr/local/bin/macbay
```

설치 확인:

```sh
mb --version
# 출력: 1.2.1
```

---

## 빠른 시작

### 0. 대화형 TUI 모드 (기본 실행)

터미널에서 인자 없이 `mb`만 입력하면 키보드로 조작하는 TUI가 열립니다:

```sh
mb
# 또는 명시적으로 실행:
mb tui
```

> [!NOTE]
> 비대화형 환경(스크립트, CI, 파이프 연결)이거나 `TERM`이 지원되지 않는 경우 `mb`는 표준 CLI 도움말을 출력합니다. 비대화형 환경에서 `mb tui`를 직접 실행하면 오류 안내와 함께 종료됩니다.

#### 키보드 조작법

| 키 | 동작 |
| --- | --- |
| `↑` / `↓` 또는 `j` / `k` | 메뉴 및 목록 탐색 |
| `Enter` | 메뉴 선택 및 작업 실행 |
| `Esc` | 이전 화면으로 뒤로가기 |
| `q` | MacBay TUI 종료 |
| `r` | 현재 화면 데이터 새로고침 |
| `←` / `→` 또는 `Tab` | 확인 대화상자 버튼 전환 (Cancel / Confirm) |

#### TUI 지원 범위

- **홈**: 내장 및 외장 APFS 디스크 용량, MacBay 관리 중인 앱 수 조회.
- **앱 이동 (`dock`)**: 스캔 기준을 사용한 크기순 목록, `[Safe]` / `[Review]` / `[Blocked]` 호환성 뱃지 표시. 상세 경로·호환성 근거 확인, 세션 대상 볼륨 선택, 공간 추정치를 포함한 dry-run 미리보기 후 실행 확인. (Review 대상은 위험 수락 후 `--force`로 안전하게 연결)
- **앱 복원 (`undock`)**: 연결된 볼륨의 MacBay 관리 앱을 내장 디스크로 안전하게 복원. 비관리 앱은 이 화면에서 바로 등록할 수 있습니다. 현재 위치, 표준 저장 경로, 링크 변경, 파일 이동 여부를 검토하고 확인하면 복원 미리보기가 준비됩니다. 등록 대상은 앱이 실제로 있는 볼륨이며 설정된 기본 볼륨으로 임의 변경하지 않습니다. 확인 불가 항목 및 깨진 링크는 상태 안내와 `mb doctor` 안내를 표시합니다.
- **진단 (`doctor`)**: 외장화한 앱과 개발 데이터의 링크 끊김, 대상 누락, 기록 불일치, 중단된 작업을 살펴보고 문제별 권장 조치를 확인합니다.
- **검색·필터**: 이동·복원 목록에서 `/`로 앱 이름을 검색합니다(대소문자 무시). Enter는 적용, Esc는 검색 초기화입니다. `f`는 호환성 검사 통과 앱/관리 앱 필터, `s`는 이름·크기 정렬, `c`는 검색·필터 초기화입니다. 기존 위험 확인 단계는 유지됩니다.
- **복사 진행률**: 이동·복원 중 대상 파일 크기를 관찰해 복사 용량·비율·평균 증가 속도를 추정합니다. 사전 할당된 파일 크기가 실제 전송보다 앞설 수 있어 검증된 전송량이나 디스크 속도를 의미하지 않습니다. 복사 중에는 100%로 표시하지 않으며, 서명 검증은 별도 단계입니다. 측정이 불가능하거나 비용이 크면 단계·경과 시간만 표시합니다.
- **진단에서 복구**: 로컬·외장 중복 앱 진단에서 `p`로 비교 후 재이동/로컬 유지 계획을 확인합니다. 중단된 repair는 `b`로 일치하는 저널과 롤백 계획을 확인합니다. 실행은 취소가 기본인 별도 확인을 거치고, 위험 앱은 명시적으로 위험을 수락해야 합니다. `r`은 진단을 다시 실행합니다. 중단된 adopt는 repair 롤백으로 처리하지 않습니다.
- 다중 선택과 Xcode·캐시 TUI 실행은 후속 범위이며 현재는 CLI를 사용합니다.

### 1. 스토리지 상태 확인

내부 드라이브 여유 공간, 마운트된 외장 볼륨 및 부적격 드라이브 상태를 확인합니다:

```sh
mb status
```

출력 예시:
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

### 2. 외장화 대상 탐색

대용량 애플리케이션, 개발자 캐시, 이미 외장으로 옮긴 앱 및 비정상 심볼릭 링크를 검색합니다:

```sh
mb scan
```

출력 예시:
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

전체 애플리케이션 경로 및 호환성 분석 상세 근거/이유를 확인하려면:
```sh
mb scan --verbose
```

- **애플리케이션 (Applications)**: 내장 디스크에 위치한 대용량 앱(200 MB 이상)과 호환성 등급(`Safe`, `Review`, `Blocked`).
- **개발자 캐시 (Developer caches)**: 대용량 개발 도구 캐시(예: CoreSimulator, npm cache).
- **이미 외장화된 앱 (Already external)**: 이미 외장 스토리지로 이전된 애플리케이션:
  - `MacBay`: 외장 볼륨의 `manifest.json`에 기록되어 MacBay가 관리 중인 앱.
  - `Unmanaged`: 수동 또는 다른 도구로 외장에 이전되어 MacBay 기록이 없는 앱.
  - `Unconfirmed`: 외장 볼륨에 있으나 매니페스트 확인 중 오류가 발생한 상태.
- **연결 끊긴 링크 (Unresolved links)**: 대상이 없거나(`Target unavailable`), 순환 링크, 볼륨 확인 실패 등의 비정상 링크.

### 3. 링크·기록 진단

애플리케이션 링크, 개발자 캐시 링크, 연결된 볼륨의 MacBay 기록이 실제 상태와 일치하는지 확인합니다. `doctor`는 읽기 전용이며 파일을 변경하지 않습니다:

```sh
mb doctor
```

출력 예시:
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

- `Healthy`: 링크가 정상적으로 해석되고 MacBay 기록 또는 기대 레이아웃과 일치합니다. 기록이 없는 링크는 문제가 아니라 `unmanaged` 정보로 표시합니다.
- `Needs attention`: 끊어진 링크, 순환 링크, 기록된 대상 경로와 실제 대상이 다른 경우, 기록된 복사본이나 원본 경로가 사라진 경우, 링크여야 할 자리에 일반 파일·디렉터리가 생긴 경우.
- `Unable to verify`: 링크, 링크 대상 볼륨, 볼륨의 `manifest.json`을 읽지 못한 경우(권한 오류, 매니페스트 오류 등).
- `Notes`: 검사 범위를 안내합니다. 수동 이동 항목은 MacBay 이력이 없어 평가하지 않으며, 기록을 읽지 못한 볼륨의 항목은 검사하지 않았다는 점을 명시합니다.
- `Nothing to verify`(검사할 기록·링크가 없음)는 "문제 없음"과 구분해서 표시합니다.

종료 코드: 문제 없음 `0`, 문제 또는 검증 불가 항목 발견 `1`, 진단 자체 실패(예: `--volume` 경로 확인 불가) `2`.

> [!NOTE]
> MacBay는 연결된 외장 볼륨에서만 기록을 읽으므로 분리된 드라이브는 검증할 수 없습니다. 진단은 실제로 확인한 범위를 보고하며, 대상이 사라진 이유를 디스크 분리나 데이터 삭제로 단정하지 않습니다.

---

## 명령어 및 사용법

### 명령어 축약

축약 명령은 기존 명령과 같은 인자와 옵션을 사용합니다. `mb --help`에서도 확인할 수 있습니다.

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
| `purge` | `pu` |
| `teardown` | `td` |
| `tui` | `ui` |

```sh
mb st
mb sc --json
mb doc
mb dk --help
```

### 기본 볼륨 선택 (`init`)

`--volume`을 생략했을 때 변경 명령이 사용할 외장 볼륨을 저장합니다. `dock`, `undock`, `adopt`, `xcode`, `cache`가 항상 같은 드라이브를 대상으로 동작합니다:

```sh
# 적격 볼륨이 하나뿐이면 바로 저장하고, 터미널에서는 번호 목록으로 선택합니다
mb init

# 확인 없이 특정 볼륨을 기본값으로 저장
mb init --volume /Volumes/ExternalSSD

# 저장된 기본값 출력
mb init --show

# 저장된 기본값 삭제
mb init --reset
```

기본값은 볼륨 UUID와 함께 `$XDG_CONFIG_HOME/macbay/config.json`(또는 `~/.config/macbay/config.json`)에 저장되므로, 드라이브가 다른 이름으로 마운트되어도 기본값을 찾을 수 있습니다. 저장된 볼륨이 연결되어 있지 않으면 변경 명령은 다른 드라이브로 조용히 넘어가지 않고 중단합니다. `mb status`와 `mb doctor`가 해당 상태를 보고하며, `mb init`을 다시 실행하면 확인 후 기본값을 교체합니다.

### 링크·기록 진단 (`doctor`)

/Applications의 링크, 알려진 개발자 캐시 링크, 연결된 외장 볼륨(읽기 전용 포함)의 MacBay 기록을 검사합니다. 파일과 설정을 변경하지 않습니다:

```sh
# 연결된 볼륨과 로컬 링크 진단
mb doctor

# /Volumes 밖에 마운트된 볼륨을 추가 검사
mb doctor --volume /Volumes/Archive
```

**검사 항목**:
1. **애플리케이션 링크**: `/Applications`의 모든 심볼릭 링크를 해석합니다(상대·연쇄·순환 링크 포함).
2. **개발자 캐시 링크**: `~/Library/Developer/Xcode/iOS DeviceSupport`, `~/Library/Developer/CoreSimulator`, `~/.npm`, `~/.cache/uv`, `~/.gradle`, `~/.cache/huggingface`.
3. **볼륨 기록**: 연결된 볼륨의 `MacBay/manifest.json`과 실제 원본·대상 경로를 대조합니다.
4. **내부 데이터**: 기록된 원본 경로가 링크가 아니라 일반 파일·디렉터리로 존재하면 `Local data detected`로 보고하고 두 경로와 현재 크기를 표시합니다. 외장 복사본까지 사라졌다면 단순 중복으로 분류하지 않고 기록과 실제 상태가 다름으로 보고합니다.
5. **중단된 작업**: 볼륨에 남은 미완료 `adopt`·`repair` 작업을 롤백·완료에 필요한 명령과 함께 보고합니다.

> [!NOTE]
> `doctor`는 삭제·덮어쓰기·재이동을 수행하지 않으며, "업데이트 때문에 재생성됐다"거나 "두 복사본이 동일하다"고 단정하지 않습니다. 수동 이동 항목은 MacBay 이력이 없어 내부 데이터 검사에서 제외되며, 이 범위는 `notes`에 명시됩니다.

**결과 그룹**: `Healthy`, `Needs attention`, `Unable to verify`와 MacBay가 만들지 않은 링크를 위한 `unmanaged` 정보. 모든 문제는 `--json` 출력에서 안정적인 진단 코드와 권장 행동을 함께 제공합니다.

**종료 코드**: 정상 `0`, 문제 또는 검증 불가 `1`, 진단 자체 실패 `2`.

> [!IMPORTANT]
> `doctor`는 읽기 전용입니다. 삭제·이동·복구를 수행하지 않으며 내부 디스크에 별도 기록을 저장하지 않으므로, 분리된 외장 볼륨은 다시 연결하기 전까지 검증할 수 없습니다.

### 저장된 앱 경로 검사 (`references`)

특정 설정 파일 안에 저장된 앱 경로를 검사합니다. `--path`로 지정한 파일만 읽고 디스크의 다른 위치는 탐색하지 않습니다:

```sh
# 파일 하나 검사
mb references --path ~/.cursor/mcp.json

# 여러 파일 검사 (반복 가능)
mb references --path ~/.cursor/mcp.json --path ~/Library/LaunchAgents/com.example.tool.plist
```

JSON과 XML·바이너리 plist는 Foundation으로 읽고, TOML·YAML·INI·셸 등 텍스트 파일에서는 `.app` 경계를 포함하는 절대 경로를 추출합니다. 상대 경로는 현재 디렉터리 기준, `~`는 홈 기준이며, 중복 지정한 경로는 한 번만 검사합니다. 저장된 경로가 실제로 존재하는지와 대체 후보를 확인하기 위해 `/Applications`와 `~/Applications`를 조회합니다. 볼륨·매니페스트 검사는 실행하지 않습니다.

저장된 경로가 없으면 `/Applications`와 `~/Applications`에서 같은 이름의 앱을 찾습니다(같은 실제 앱이면 `/Applications`를 우선). 동일한 내부 경로가 있으면 `external_reference_stale_candidate`와 현재 후보를 보고하고, 대응 앱이나 내부 파일이 없으면 `external_reference_missing`입니다. 접근 오류·순환 링크·동명 앱 모호는 `external_reference_unverified`, 읽기 한도는 `external_reference_scan_incomplete`입니다.

> [!NOTE]
> 참조 검사는 읽기 전용입니다. 경로처럼 보이는 문자열의 휴리스틱 추출은 지원되는 검사 방식이며, MacBay는 셸 변수를 확장하거나 스크립트를 실행하지 않고, 설정이 있다고 해서 현재 사용 중이라고 단정하지 않습니다. 알려진 MCP 영역(TOML의 `mcp_servers`, JSON의 `mcpServers`)에서는 비활성 서버를 건너뛰고, 지원하지 않는 TOML 구성은 부분 검사로 보고합니다. 보고된 경로는 후보일 뿐이며, 앱이 이동·삭제됐다거나 두 복사본이 같은 버전인지, 해당 설정이 현재 사용되는지는 확정하지 않습니다. 경로 와일드카드, `<AppName>` 같은 템플릿 토큰, 문자 그대로의 `AppName.app` 자리는 파일 참조로 검사하지 않으며, 해당 제외 정책에 걸린 항목은 finding에서 제외하고 `notes`에 설명합니다. 외장 볼륨 미연결은 가능한 원인으로만 안내합니다. 저장된 경로가 잘못된 것 같으면 해당 설정이 현재 사용되는지 먼저 확인한 뒤 파일을 백업하고 경로를 수정하세요(예: `/Applications/<App>.app/...`). MacBay는 그 파일을 편집하지 않습니다.

> [!NOTE]
> 한도는 설정 파일 10,000개, 파일당 2 MiB, 총 읽기 64 MiB입니다. 백업 파일은 건너뜁니다.

**종료 코드**: 저장된 경로가 모두 정상이면 `0`, 누락 경로·읽기 실패·읽기 누락이 있으면 `1`, 인자가 잘못되었거나 검사 자체가 실패하면 `2`.

### 애플리케이션 이전 (`dock`)

애플리케이션 번들을 외장 볼륨으로 이전하고, `/Applications/<App>.app` 위치에 심볼릭 링크를 생성합니다.

```sh
# 먼저 --dry-run으로 시뮬레이션 확인
mb dock Example.app --dry-run

# 실제 이전 실행
mb dock Example.app
```

미리보기 출력 예시:
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

미리보기는 대상 볼륨의 여유 공간, 복사 후 예상 여유 공간, 내장 디스크에서 확보될 것으로 예상되는 공간, 그리고 대상 공간이 부족할 때 부족한 용량을 함께 표시합니다. 논리적 파일 크기를 기준으로 한 보수적인 추정치이므로 APFS 공유 블록과 스냅샷에 따라 실제 확보량이 달라질 수 있습니다. 실제 실행은 여유 공간을 다시 확인하고, 부족하거나 확인할 수 없으면 복사 전에 중단합니다. 공간이 충분하다는 추정이 이전 성공을 보장하지는 않습니다.

**동작 원리**:
1. **유효성 검사**: 번들 무결성, 실행 중인 프로세스(`lsof`), SQLite 파일 잠금(`-wal`, `-shm`)을 확인합니다.
2. **호환성 검사**: 코드 서명 권한(entitlement)과 재배치 마커를 검사합니다.
3. **원자적 복사 및 검증**: `ditto`를 통해 메타데이터를 유지하며 번들을 복사하고, `codesign --verify --deep --strict`로 서명 무결성을 검증합니다.
4. **심볼릭 링크 대체**: 원본 번들을 심볼릭 링크로 원자적으로 교체합니다.
5. **시스템 갱신**: 흰색 기본 아이콘이 표시되지 않도록 LaunchServices 등록 정보(`lsregister -f`)를 갱신하고 Dock 프로세스를 재시작합니다.

> [!NOTE]
> 애플리케이션이 ⚠️ **Review** (JSON의 `POPUP_RISK`) 등급으로 분류된 경우, 잠재적 위험 요소를 검토한 후 `--force` 플래그를 추가하여 진행할 수 있습니다:
> ```sh
> mb dock HeavyStudio.app --force --dry-run
> ```

> [!TIP]
> `/Applications` 내의 애플리케이션이 이미 MacBay 외부에서 외장 스토리지로 연결된 심볼릭 링크인 경우, `mb dock`은 이를 감지하고 대신 `mb adopt` 명령을 사용할 것을 안내합니다.

### 애플리케이션 복원 (`undock`)

외장화된 애플리케이션을 `/Applications`의 원래 위치로 복원하고 외장 드라이브의 복사본을 정리합니다:

```sh
# 복원 시뮬레이션 미리보기
mb undock Example.app --dry-run

# 내부 디스크로 복원 실행
mb undock Example.app
```

복원 시에도 필요한 공간을 미리 보여줍니다: 내장 볼륨의 여유 공간, 복사 후 예상 여유 공간, 부족분입니다. 실제 실행 시 내장 볼륨을 다시 확인하며, 공간이 부족하거나 확인할 수 없으면 복사 전에 중단합니다.

### 외장 애플리케이션 수용 (`adopt`)

이미 외장 스토리지에 존재하는 애플리케이션을 내장 디스크로 다시 복원하지 않고도 MacBay 표준 경로(`<Volume>/MacBay/Applications/<App>.app`)로 재배치하고, `/Applications/<App>.app` 심볼릭 링크를 갱신하며, `manifest.json`에 정식 관리 대상으로 등록합니다:

```sh
# 먼저 --dry-run으로 시뮬레이션 확인
mb adopt ChatGPT.app --volume /Volumes/ExternalSSD --dry-run

# 실제 수용 실행
mb adopt ChatGPT.app --volume /Volumes/ExternalSSD
```

미리보기 출력 예시:
```text
Dry run: adopt ChatGPT.app
  Size: 120.5 MB
  Source: /Volumes/ExternalSSD/Applications/ChatGPT.app
  Destination: /Volumes/ExternalSSD/MacBay/Applications/ChatGPT.app
  Symlink: /Applications/ChatGPT.app -> /Volumes/ExternalSSD/MacBay/Applications/ChatGPT.app
  Space: no additional space required (same volume relocation)
  Dry run: no files were changed
```

**동작 원리**:
1. **대상 위치 탐색**: `/Applications/<App>.app` 심볼릭 링크를 추적하여 외장 APFS 볼륨 내 실제 원본 앱 번들 위치를 확인합니다.
2. **안전성 및 호환성 검사**: 활성 프로세스(`lsof`), SQLite 잠금(`-wal`, `-shm`), 코드 서명 무결성 및 이전 차단 요소를 검사합니다. ⚠️ **Review** (`POPUP_RISK`) 등급 앱은 `--force`가 필요합니다.
3. **저널링 및 복구 추적**: 작업 진행 상황을 외장 볼륨 내 저널(`.operations/adopt-<id>.json`)에 기록합니다. 도중 중단된 작업은 `mb doctor`가 감지하여 `incomplete_operation`으로 보고합니다.
4. **원자적 재배치**: 동일 APFS 볼륨 내에서 번들을 표준 경로로 원자적 이동합니다 (이미 표준 위치에 있는 경우 이동 생략).
5. **원자적 심볼릭 링크 갱신**: `/Applications/<App>.app` 심볼릭 링크를 새로운 표준 경로로 원자적 교체합니다.
6. **매니페스트 등록**: 멀티 프로세스 파일 락(`flock`) 하에서 `MacBay/manifest.json`에 안전하게 등록합니다.
7. **시스템 갱신**: LaunchServices 등록 정보(`lsregister -f`)를 갱신하고 Dock 프로세스를 재시작합니다.

### 중복 앱 비교 및 복구 (`repair`)

`mb doctor`에서 매니페스트에 등록된 앱의 내장 경로(`/Applications`)에 실제 앱 번들이 다시 감지되고 외장 사본도 존재하는 경우(`local_data_detected`), `mb repair`를 통해 안전하게 비교하고 복구할 수 있습니다:

```sh
# 1. 읽기 전용 비교 (버전, 빌드, 식별자, 서명, 크기)
mb repair "Kiro CLI.app"

# 2. 내장 앱 외장 재이동 (redock) 미리보기
mb repair "Kiro CLI.app" --action redock --dry-run

# 3. 내장 앱 유지 및 관리 해제 (keep-local) 미리보기
mb repair "Kiro CLI.app" --action keep-local --dry-run

# 4. 실제 실행
mb repair "Kiro CLI.app" --action redock
mb repair "Kiro CLI.app" --action keep-local

# 5. 중단된 복구 작업 롤백 복원
mb repair "Kiro CLI.app" --rollback
```

**비교 출력 예시**:
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

**안전성 및 백업 정책**:
- **식별자 일치 필수**: `redock`은 두 경로의 번들 식별자(`CFBundleIdentifier`)가 일치해야 진행됩니다. 다른 앱을 덮어쓰는 실수를 방지합니다.
- **이전 외장 사본 백업 보관**: `redock` 실행 시 기존 외장 앱은 `<Volume>/MacBay/Backups/<작업ID>/<App>.app`으로 안전하게 이동된 후 새 앱이 배치됩니다. 백업 사본은 자동 삭제되지 않고 영구 보관됩니다.
- **독립된 복구 저널**: 작업 상태는 `<Volume>/MacBay/.operations/repair-<App>.json`(버전 1)에 안전하게 기록됩니다. 작업이 중단된 경우 `mb doctor`가 감지하여 `mb repair "<App>" --rollback`으로 복원하도록 안내합니다.
- **내장 유지 (keep-local)**: 매니페스트 항목만 원자적으로 제거하며, 내장 앱과 외장 사본은 파일시스템에서 전혀 삭제되지 않고 외장 사본은 비관리 보관 사본이 됩니다.

### 임의 디렉터리 이전 (`move` / `unmove`)

게임 라이브러리, VM 디스크, 데이터셋, 미디어 폴더 등 어떤 디렉터리든 외장 볼륨의 `<Volume>/MacBay/Data/<name>`으로 옮기고 원래 위치를 심볼릭 링크로 대체합니다. 항목은 `manifest.json`에 `directory` 종류로 기록되어 `mb status`, `mb doctor`, `mb teardown`이 모두 인식합니다:

```sh
# 항상 --dry-run으로 먼저 미리보기
mb move ~/Games --dry-run

# 디렉터리 외장화
mb move ~/Games

# 내장 저장소로 복원
mb unmove ~/Games --dry-run
mb unmove ~/Games
```

**동작 방식**:
1. **검증**: 심볼릭 링크, 비-디렉터리, `.app` 번들(`mb dock` 사용), 보호된 시스템 위치(`/System`, `/Library`, `/usr`, `/Applications`, `/Volumes`, 홈 루트, `~/Library` 등), 이미 비내장 볼륨에 있는 소스, 그리고 `mb cache`가 이미 관리하는 경로를 거부합니다. `~/Library` 안에서는 `Containers`, `Group Containers`, `Mobile Documents`, `Keychains`, `Mail`, `Preferences`, `Developer` 등 공유/시스템 하위 트리는 옮길 수 없고, `~/.ssh`, `~/.gnupg`, `~/.cargo`, `~/.rustup` 같은 자격 증명 디렉터리도 차단됩니다. `Application Support`와 `Caches` 루트 자체는 차단되지만 그 하위 디렉터리는 옮길 수 있습니다(예: `~/Library/Application Support/Steam`).
2. **안전성**: 실행 중인 프로세스(`lsof`)와 SQLite 잠금을 확인하고, 디렉터리 크기를 측정하며, 외장 여유 공간을 미리 보여줍니다.
3. **복사 및 링크**: `ditto`로 진행률 샘플링과 함께 복사한 뒤, 소스를 심볼릭 링크로 원자적으로 교체합니다.
4. **매니페스트**: `<Volume>/MacBay/manifest.json`에 이전을 기록하여 `mb unmove` 또는 `mb teardown`으로 복원할 수 있게 합니다.

`unmove`는 심볼릭 링크를 해석하고, 외장 사본을 다시 복사하고, 링크와 외장 사본을 제거하며, 매니페스트 기록을 삭제합니다. 기록이 있는 항목은 매니페스트를 통해 복원되고, 기록 없이 MacBay 스토리지를 가리키는 링크는 표준 `MacBay/Data/` 레이아웃 아래에 있을 때만 복원되며, 그 외 위치로의 링크는 거부됩니다.

> [!NOTE]
> `mb move`는 `mb dock`처럼 애플리케이션이 이전 후에도 계속 동작하게 만드는 절차(codesign 검증, LaunchServices 갱신, Dock 재시작)를 수행하지 않습니다. `.app` 번들에는 `dock`을 사용하세요.

### Xcode 유지 관리 (`xcode`)

`~/Library/Developer/Xcode/iOS DeviceSupport` 디렉터리를 외장 볼륨으로 이전하고, 사용 불가능한 iOS 시뮬레이터 데이터를 정리합니다:

```sh
# Xcode 외장화 미리보기
mb xcode --dry-run

# Xcode 유지 관리 실행
mb xcode
```

> [!TIP]
> 이미 외장 볼륨(예: `/Volumes/<Drive>/Developer/Xcode/iOS DeviceSupport`)을 가리키는 심볼릭 링크가 존재하는 경우, MacBay는 불필요한 재이전 작업 없이 해당 링크 대상을 인식하고 유효성을 검증합니다.

### 개발자 캐시 경로 재지정 (`cache`)

`~/.zshrc` 파일에 격리 관리되는 설정 블록을 추가하여 개발 패키지 캐시를 외장 스토리지로 라우팅합니다:

```sh
# 캐시 리디렉션 미리보기
mb cache --enable --dry-run

# 외장 캐시 라우팅 활성화
mb cache --enable

# ~/.zshrc에서 관리 블록 제거 및 초기화
mb cache --reset
```

관리 대상 캐시 목록:
- `npm`: `npm_config_cache`
- `pnpm store`: `npm_config_store_dir`
- `Yarn Berry 캐시` (`~/.yarn/berry/cache`): 심볼릭 링크 전용 — 전역 캐시가 켜진 기본 설정에서 Berry는 `YARN_CACHE_FOLDER`를 무시하고, 이 변수는 zero-install 저장소가 쓰는 프로젝트 `cacheFolder` 설정까지 덮어쓰기 때문입니다
- `Yarn v1 캐시` (`~/Library/Caches/Yarn`): 같은 이유로 심볼릭 링크 전용
- `bun 캐시`: `BUN_INSTALL_CACHE_DIR`
- `uv`: `UV_CACHE_DIR`
- `pip`: `PIP_CACHE_DIR`
- `Gradle`: `GRADLE_USER_HOME`
- `CocoaPods`: `CP_HOME_DIR`
- `Go 모듈`: `GOMODCACHE`
- `Android 사용자 데이터`: `ANDROID_USER_HOME`
- `Homebrew 다운로드`: `HOMEBREW_CACHE`
- `Hugging Face`: `HF_HOME`

> [!NOTE]
> Cargo(`~/.cargo`)는 의도적으로 라우팅하지 않습니다. `CARGO_HOME`에는 `~/.cargo/bin`의 rustup shim도 있어서, 이를 옮기면 드라이브가 분리될 때마다 `cargo`/`rustup`이 깨집니다. 특정 대용량 프로젝트 디렉터리는 `mb move`로 옮기세요.

### 전체 정리 (`teardown`)

MacBay가 관리하는 모든 것을 한 번에 되돌립니다 — 삭제 전이나 다른 외장 드라이브로 옮길 때 유용합니다:

```sh
# 전체 teardown 미리보기
mb teardown --dry-run

# 모든 관리 항목 복원 및 설정 초기화
mb teardown

# 한 볼륨으로 제한
mb teardown --volume /Volumes/ExternalSSD
```

**동작 방식**:
1. **기록 복원**: 연결된 각 적격 볼륨(또는 `--volume`)의 모든 매니페스트 항목을 복원합니다 — 애플리케이션은 `undock`, move된 디렉터리는 `unmove` 경로로.
2. **알려진 링크 정리**: 매니페스트 기록 없이 심볼릭 링크로 남은 개발자 위치(Xcode 대상, 캐시 대상)를 정리합니다: `MacBay/Caches/` 안의 링크는 제거 후 빈 디렉터리로 교체하고(외장 사본은 비관리 보관본으로 유지), 다른 `MacBay/` 루트의 링크는 내장으로 완전히 복원합니다.
3. **설정 초기화**: 실패가 없는 *전체* teardown(`--volume` 생략)일 때만 `~/.zshrc`의 관리 블록을 제거하고 저장된 기본 볼륨을 잊습니다. 기본 볼륨은 실제로 이번 teardown 대상이었을 때만 잊습니다 — 마운트되지 않은 볼륨은 note와 함께 유지되어 나중에 데이터에 다시 접근할 수 있습니다. 대상 밖 볼륨의 MacBay 디렉터리를 가리키는 캐시 링크는 조용히 넘기지 않고 건너뛰었음을 보고합니다.
4. **보고**: 항목별 실패를 중단 없이 수집하며, 하나라도 실패하면 종료 코드가 `1`입니다. 각 볼륨의 `MacBay/` 디렉터리 자체는 남겨둡니다 — 백업과 기록되지 않은 데이터는 절대 삭제하지 않습니다 — 보고서의 notes에 남은 디렉터리를 안내합니다.

> [!IMPORTANT]
> `teardown`은 데이터를 내장 디스크로 다시 복사합니다. 내장 공간이 부족하면 항목별로 오류와 함께 중단되므로, 먼저 `mb teardown --dry-run`으로 어떤 일이 일어날지 확인하세요.

### 애플리케이션 캐시 정리 (`purge`)

내장 SSD 상의 불필요하고 비대한 재생성 캐시들을 안전하게 검사하고 정리합니다. 폴더를 이동하거나 사용자 계정에 영향을 주지 않습니다:

```sh
# 정리 가능한 캐시 및 절약 예상 용량 미리보기
mb purge --dry-run

# 화이트리스트 캐시 검사 및 대화형 확인 후 정리
mb purge

# 확인 프롬프트 없이 즉시 정리 실행
mb purge --yes

# 특정 애플리케이션만 지정하여 캐시 정리 (예: Slack, Discord, Chrome)
mb purge --app Slack

# 현재 실행 중인 애플리케이션의 캐시도 포함하여 강제 정리
mb purge --include-running

# 진단 크래시 리포트 및 로그 포함 (~/Library/Logs/DiagnosticReports)
mb purge --include-logs

# Homebrew 다운로드 캐시 제외
mb purge --no-homebrew
```

**무손실 안전 모델**:
- **엄격한 화이트리스트 폴더 대상**: 완전히 자동 재생성 가능한 Chromium/Electron 캐시 디렉터리(`CacheStorage`, `Code Cache`, `GPUCache`, `GPUPersistentCache`, `DawnCache`, `blob_storage`), Electron 업데이트 설치 파일(`Library/Caches/<App>/ShipIt`), Homebrew 다운로드 캐시만 정리합니다.
- **사용자 데이터 절대 보존**: SQLite 데이터베이스(`.sqlite`, `.db`, `.wal`), 로그인 세션 및 인증 정보(`IndexedDB`, `Cookies`, `Local Storage`), 사용자 설정 파일(`settings.json`, `.plist`)은 절대 삭제 대상에 포함되지 않습니다.
- **실행 중인 앱 보호**: 시스템 프로세스 목록(`/bin/ps`)을 검사하여 현재 실행 중인 앱의 캐시는 I/O 충돌을 방지하기 위해 기본적으로 건너뜁니다(`--include-running`으로 강제 포함 가능).
- **디렉터리 구조 유지**: 대상 캐시 디렉터리 자체와 권한은 유지한 채 내부의 캐시 파일들만 비웁니다.

---

## 외장 볼륨 요구 조건 및 제한 사항

데이터 무결성을 보장하기 위해 MacBay는 엄격한 볼륨 적격성 기준을 적용합니다:

| 요구 조건 | 규칙 | 설정 근거 |
| :--- | :--- | :--- |
| **마운트 경로** | `/Volumes/` 하위에 마운트되어야 함 | macOS 표준 외장 볼륨 계층 구조 준수 |
| **드라이브 유형** | 물리 외장 드라이브 (`Internal == false`) | 기본 내부 드라이브로 다시 외장화되는 현상 방지 |
| **파일시스템** | **APFS** (`FilesystemType == apfs`) | APFS 복제(clone), 심볼릭 링크, 메타데이터 기능 필수 |
| **권한** | 쓰기 가능 (`WritableVolume == true`) | 읽기 전용 드라이브에는 애플리케이션 번들 호스팅 불가 |
| **프로토콜** | `BusProtocol != "Disk Image"` | 임시 설치용 DMG 디스크 이미지 자동 제외 |

- **선택 우선순위**: `--volume`(또는 `-v`)이 최우선이고, 그다음이 `mb init`으로 저장한 기본값, 마지막이 자동 감지입니다.
- **자동 선택**: 마운트된 적격 외장 볼륨이 정확히 하나인 경우, MacBay가 이를 자동으로 선택합니다.
- **복수 볼륨**: 두 개 이상의 적격 드라이브가 연결되어 있는 경우, 의도하지 않은 드라이브에 쓰는 것을 방지하기 위해 `--volume <path>`(또는 `-v`) 옵션 지정이 필수입니다. `mb init`으로 기본값을 저장하면 매 명령마다 옵션을 붙이지 않아도 됩니다.
- **저장된 기본값**: `mb init`은 적격 볼륨 하나를 `~/.config/macbay/config.json`(`$XDG_CONFIG_HOME` 존중)에 저장하며, 기본값을 사용할 수 없을 때 다른 드라이브로 조용히 전환하지 않습니다.

---

## 안전 모델 및 호환성 등급

번들을 마이그레이션하기 전에 `AppInspector`가 애플리케이션을 분석하여 등급을 매깁니다:

- 🟢 **Safe** (JSON의 `SAFE`): 재배치 훅이나 가상화 요구 조건이 없는 깔끔한 번들 구조입니다. 표준 이전 작업이 안전하게 가능합니다.
- ⚠️ **Review** (JSON의 `POPUP_RISK`): 애플리케이션에 자체 재배치 검사 로직(예: Mach-O/ASAR 내 `moveToApplicationsFolder`, `PFMoveToApplicationsFolder`)이나 권한 상승 헬퍼 도구(`SMPrivilegedExecutables`)가 포함되어 있습니다. 이전하려면 `-f, --force` 플래그가 필요합니다.
- ❌ **Blocked** (JSON의 `BLOCKED`): 하이퍼바이저/가상화 권한(`com.apple.security.virtualization`)이 필요하거나, Driver/System/Kernel Extension을 포함하고 있거나, 코드 서명이 손상된 애플리케이션입니다. **시스템 불안정을 방지하기 위해 마이그레이션이 차단됩니다.**

---

## 외장 볼륨 디렉터리 레이아웃

외장화를 수행하면 MacBay는 외장 드라이브에 다음과 같은 디렉터리 구조를 구성 및 유지합니다:

```text
/Volumes/<ExternalDrive>/MacBay/
├── Applications/       # 이전된 애플리케이션 번들
├── Caches/             # npm, uv, Gradle 등 개발자 캐시
├── Data/               # `mb move`로 이전된 디렉터리
├── Xcode/              # iOS DeviceSupport 심볼 캐시
└── manifest.json       # 이전된 모든 항목의 Codable 메타데이터 매니페스트
```

---

## JSON 출력 및 자동화

모든 명령어는 스크립트, CI 파이프라인, AI 에이전트 도구와의 연동을 위해 `--json` 플래그를 지원합니다:

```sh
mb status --json
```

`mb doctor --json`은 `volumes`, `findings`, `summary`, `warnings`, `notes`를 보고합니다. 각 항목에는 안정적인 `code`(예: `link_target_unavailable`, `link_unmanaged`, `local_data_detected`, `record_source_missing`, `manifest_unreadable`), `status`(`healthy`, `needs_attention`, `unable_to_verify`), 관련 경로와 크기(해당되는 경우), 권장 행동이 포함됩니다.

`mb references --json`은 `generatedAt`, `findings`, `notes`를 보고합니다. 각 항목에는 안정적인 `code`(예: `external_reference_stale_candidate`, `external_reference_missing`, `external_reference_unverified`, `external_reference_scan_incomplete`, `external_config_unreadable`, `external_config_partially_checked`), `status`, 원본 파일, 저장된 경로, 확인된 대체 후보(있는 경우), 선택적 `referenceLocations`, 권장 행동이 포함됩니다.

오류 발생 시 MacBay는 `stderr`로 구조화된 에러 봉투(envelope)를 출력하고 0이 아닌 종료 상태 코드를 반환합니다:

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

## 기여하기

기여는 언제나 환영합니다! 행동 강령, 하드웨어 독립적인 테스트 환경 구축, 기여 절차에 대한 자세한 내용은 [CONTRIBUTING.md](../CONTRIBUTING.md)를 참조해 주세요.

---

## 라이선스

MacBay는 [MIT 라이선스](../LICENSE) 하에 배포되는 오픈 소스 소프트웨어입니다. Copyright © 2026 thingk0.
