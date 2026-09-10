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

MacBay는 Apple Silicon Mac을 위해 설계된 개발자 중심의 스토리지 외장화 도구입니다. 대용량 애플리케이션, Xcode DeviceSupport 데이터, 개발자 캐시를 외장 APFS 드라이브로 안전하게 이전하면서도 터미널 CLI, LaunchAgent, macOS Dock에서 사용할 수 있도록 기존 경로를 투명하게 유지합니다.

[![CI](https://github.com/thingk0/macbay/actions/workflows/ci.yml/badge.svg)](https://github.com/thingk0/macbay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-orange.svg)](https://en.wikipedia.org/wiki/Apple_silicon)

---

## 주요 기능

- **애플리케이션 이전 (`dock` / `undock`)**: 대용량 앱을 외장 스토리지로 마이그레이션하고 원본 위치를 심볼릭 링크로 대체합니다. Dock 아이콘과 LaunchServices 등록 정보가 자동으로 갱신됩니다.
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
# 출력: 1.0.0
```

---

## 빠른 시작

### 1. 스토리지 상태 확인

내부 드라이브 여유 공간, 마운트된 외장 볼륨 및 부적격 드라이브 상태를 확인합니다:

```sh
mb status
```

### 2. 외장화 대상 탐색

안전성 평가 결과와 함께 대용량 애플리케이션 및 개발자 캐시를 검색합니다:

```sh
mb scan
```

출력 예시:
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

## 명령어 및 사용법

### 애플리케이션 이전 (`dock`)

애플리케이션 번들을 외장 볼륨으로 이전하고, `/Applications/<App>.app` 위치에 심볼릭 링크를 생성합니다.

```sh
# 먼저 --dry-run으로 시뮬레이션 확인
mb dock Example.app --dry-run

# 실제 이전 실행
mb dock Example.app
```

**동작 원리**:
1. **유효성 검사**: 번들 무결성, 실행 중인 프로세스(`lsof`), SQLite 파일 잠금(`-wal`, `-shm`)을 확인합니다.
2. **호환성 검사**: 코드 서명 권한(entitlement)과 재배치 마커를 검사합니다.
3. **원자적 복사 및 검증**: `ditto`를 통해 메타데이터를 유지하며 번들을 복사하고, `codesign --verify --deep --strict`로 서명 무결성을 검증합니다.
4. **심볼릭 링크 대체**: 원본 번들을 심볼릭 링크로 원자적으로 교체합니다.
5. **시스템 갱신**: 흰색 기본 아이콘이 표시되지 않도록 LaunchServices 등록 정보(`lsregister -f`)를 갱신하고 Dock 프로세스를 재시작합니다.

> [!NOTE]
> 애플리케이션이 ⚠️ **POPUP_RISK** 등급으로 분류된 경우, 잠재적 위험 요소를 검토한 후 `--force` 플래그를 추가하여 진행할 수 있습니다:
> ```sh
> mb dock Claude.app --force --dry-run
> ```

### 애플리케이션 복원 (`undock`)

외장화된 애플리케이션을 `/Applications`의 원래 위치로 복원하고 외장 드라이브의 복사본을 정리합니다:

```sh
# 복원 시뮬레이션 미리보기
mb undock Example.app --dry-run

# 내부 디스크로 복원 실행
mb undock Example.app
```

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

- **자동 선택**: 마운트된 적격 외장 볼륨이 정확히 하나인 경우, MacBay가 이를 자동으로 선택합니다.
- **복수 볼륨**: 두 개 이상의 적격 드라이브가 연결되어 있는 경우, 의도하지 않은 드라이브에 쓰는 것을 방지하기 위해 `--volume <path>`(또는 `-v`) 옵션 지정이 필수입니다.

---

## 안전 모델 및 호환성 등급

번들을 마이그레이션하기 전에 `AppInspector`가 애플리케이션을 분석하여 등급을 매깁니다:

- 🟢 **SAFE**: 재배치 훅이나 가상화 요구 조건이 없는 깔끔한 번들 구조입니다. 표준 이전 작업이 안전하게 가능합니다.
- ⚠️ **POPUP_RISK**: 애플리케이션에 자체 재배치 검사 로직(예: Mach-O/ASAR 내 `moveToApplicationsFolder`, `PFMoveToApplicationsFolder`)이나 권한 상승 헬퍼 도구(`SMPrivilegedExecutables`)가 포함되어 있습니다. 이전하려면 `-f, --force` 플래그가 필요합니다.
- ❌ **BLOCKED**: 하이퍼바이저/가상화 권한(`com.apple.security.virtualization`)이 필요하거나, Driver/System/Kernel Extension을 포함하고 있거나, 코드 서명이 손상된 애플리케이션입니다. **시스템 불안정을 방지하기 위해 마이그레이션이 차단됩니다.**

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

오류 발생 시 MacBay는 `stderr`로 구조화된 에러 봉투(envelope)를 출력하고 0이 아닌 종료 상태 코드를 반환합니다:

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

## 기여하기

기여는 언제나 환영합니다! 행동 강령, 하드웨어 독립적인 테스트 환경 구축, 기여 절차에 대한 자세한 내용은 [CONTRIBUTING.md](CONTRIBUTING.md)를 참조해 주세요.

---

## 라이선스

MacBay는 [MIT 라이선스](LICENSE) 하에 배포되는 오픈 소스 소프트웨어입니다. Copyright © 2026 thingk0.
