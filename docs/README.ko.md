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

MacBay는 Apple Silicon Mac을 위해 설계된 개발자 중심의 스토리지 외장화 도구입니다. 대용량 애플리케이션, Xcode DeviceSupport 데이터, 개발자 캐시를 외장 APFS 드라이브로 안전하게 이전하면서도 터미널 CLI, LaunchAgent, macOS Dock에서 사용할 수 있도록 기존 경로를 투명하게 유지합니다.

[![CI](https://github.com/thingk0/macbay/actions/workflows/ci.yml/badge.svg)](https://github.com/thingk0/macbay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-orange.svg)](https://en.wikipedia.org/wiki/Apple_silicon)

---

## 주요 기능

- **애플리케이션 이전 (`dock` / `undock` / `adopt`)**: 대용량 앱을 외장 스토리지로 마이그레이션하거나, 내장 복원 없이 기존 외장 앱을 MacBay 표준 구조로 수용합니다. Dock 아이콘과 LaunchServices 등록 정보가 자동으로 갱신됩니다.
- **안전성 검사 엔진 (`AppInspector`)**: 앱 번들의 가상화 권한(entitlement), 커널/시스템 확장(KEXT/System Extension), 하드코딩된 자체 재배치 로직 여부를 자동으로 검사합니다.
- **Xcode DeviceSupport 관리 (`xcode`)**: 방대한 용량을 차지하는 iOS DeviceSupport 심볼을 외장 드라이브로 이전하면서도 Xcode가 정상적으로 작동하도록 지원합니다. 기존 레거시 심볼릭 링크를 보존하고 사용 불가능한 시뮬레이터를 정리합니다.
- **개발자 캐시 경로 재지정 (`cache`)**: `~/.zshrc` 내에 격리 관리되는 설정 블록을 통해 npm, uv, Gradle, Hugging Face 캐시 디렉터리를 외장 스토리지로 라우팅합니다.
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
> **MacBay를 삭제하기 전에** 다음 정리 단계를 반드시 진행해 주세요:
> 1. 외장으로 이전(`dock`)된 모든 애플리케이션을 내부 저장소로 복원합니다:
>    ```sh
>    mb undock <AppName>.app
>    ```
> 2. `~/.zshrc`의 캐시 환경 변수 설정을 초기화합니다:
>    ```sh
>    mb cache --reset
>    ```
> 3. 이제 안전하게 포뮬러를 삭제합니다:
>    ```sh
>    brew uninstall macbay
>    ```

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
# 출력: 1.1.0
```

---

## 빠른 시작

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

`/Applications`의 링크, 알려진 개발자 캐시 링크, 연결된 외장 볼륨(읽기 전용 포함)의 MacBay 기록을 검사합니다. 파일과 설정을 변경하지 않습니다:

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

> [!NOTE]
> `doctor`는 삭제·덮어쓰기·재이동을 수행하지 않으며, "업데이트 때문에 재생성됐다"거나 "두 복사본이 동일하다"고 단정하지 않습니다. 수동 이동 항목은 MacBay 이력이 없어 내부 데이터 검사에서 제외되며, 이 범위는 `notes`에 명시됩니다.

**결과 그룹**: `Healthy`, `Needs attention`, `Unable to verify`와 MacBay가 만들지 않은 링크를 위한 `unmanaged` 정보. 모든 문제는 `--json` 출력에서 안정적인 진단 코드와 권장 행동을 함께 제공합니다.

**종료 코드**: 정상 `0`, 문제 또는 검증 불가 `1`, 진단 자체 실패 `2`.

> [!IMPORTANT]
> `doctor`는 읽기 전용입니다. 삭제·이동·복구를 수행하지 않으며 내부 디스크에 별도 기록을 저장하지 않으므로, 분리된 외장 볼륨은 다시 연결하기 전까지 검증할 수 없습니다.

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
- `uv`: `UV_CACHE_DIR`
- `Gradle`: `GRADLE_USER_HOME`
- `Hugging Face`: `HF_HOME`

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
├── Caches/             # npm, uv, Gradle, Hugging Face 캐시
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
