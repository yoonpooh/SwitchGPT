<p align="center">
  <img src="Assets/SwitchGPT.png" width="128" alt="SwitchGPT 아이콘">
</p>

# SwitchGPT

[English](README.md) · **한국어** · [日本語](README.ja.md) · [简体中文](README.zh-CN.md)

**ChatGPT 데스크톱 앱**의 계정을 전환하는 가벼운 macOS 메뉴 막대 앱입니다.

작은 패널 하나에서 계정을 저장하고, 남은 사용량을 확인하고, 계정을 전환할 수 있습니다. SwitchGPT는 독립적인 유틸리티로, OpenAI와 제휴하거나 OpenAI의 승인을 받은 제품이 아닙니다.

[최신 릴리스 다운로드](https://github.com/yoonpooh/SwitchGPT/releases/latest)

## 기능

- 현재 ChatGPT 세션을 유지하면서 브라우저 로그인으로 계정을 추가합니다.
- 로그인 정보를 macOS 키체인에 저장합니다.
- 이메일 주소와 요금제 배지를 표시합니다.
- 서비스가 반환한 사용 한도 구간, 남은 비율, 초기화 시각을 표시합니다.
- 사용 가능한 한도 초기화 횟수와 가장 가까운 만료 날짜를 표시합니다. 날짜에 마우스를 올리면 시간도 확인할 수 있습니다.
- 확인 후 계정을 전환합니다. 이 과정에서 ChatGPT와 로컬 백그라운드 서버를 재시작합니다.
- 카드를 드래그해 계정 순서를 바꿀 수 있으며, 현재 계정은 테두리로 강조합니다.
- 밝은 모드와 어두운 모드를 따르는 메뉴 막대 아이콘을 사용합니다.
- Mac의 기본 언어에 따라 영어·한국어·중국어 간체·일본어를 표시합니다. 그 외 언어는 영어로 표시하며, 중국어의 다른 지역·문자 변형도 이 버전에서는 간체로 표시합니다.
- 날짜는 선택된 언어 형식과 Mac의 시간대를 사용합니다.

## 요구 사항

- macOS 14 이상.
- 다운로드용 `arm64` 빌드는 Apple silicon Mac용입니다. 이번 릴리스에는 Intel 빌드를 포함하지 않았으며 검증하지도 않았습니다.
- 최신 ChatGPT 데스크톱 앱이 설치되어 있고 로그인된 상태.
- 기본 파일 기반 인증 저장 경로인 `~/.codex/auth.json` 사용.

SwitchGPT는 Chat·Work·Codex를 함께 제공하는 현재 ChatGPT 데스크톱 앱을 대상으로 합니다([OpenAI 문서](https://help.openai.com/en/articles/20001275-chatgpt-work-and-codex)). 기존 번들 식별자 `com.openai.codex`로 앱을 찾고 앱에 포함된 CLI를 사용하므로, 별도 CLI 설치는 필요하지 않습니다. 브라우저 세션은 변경하지 않습니다.

## 설치

1. [릴리스](https://github.com/yoonpooh/SwitchGPT/releases)에서 `SwitchGPT-v0.1.5-macos-arm64.zip`을 다운로드합니다.
2. ZIP 압축을 풀고 **SwitchGPT.app**을 **응용 프로그램** 폴더로 옮깁니다.
3. 앱을 실행합니다. 메뉴 막대에 양방향 화살표 아이콘이 나타나며, 일반 창이나 Dock 아이콘은 표시하지 않습니다.
4. 메뉴 막대 아이콘을 클릭하고 **계정 추가**를 선택한 뒤 브라우저 로그인을 완료합니다.

### ChatGPT에 설치 요청하기

로컬 파일과 터미널 도구를 사용할 수 있는 ChatGPT 세션에 다음 프롬프트를 붙여넣으세요.

```text
https://github.com/yoonpooh/SwitchGPT 에서 최신 SwitchGPT 릴리스를 이 Mac에 설치해 줘. 릴리스가 내 Mac을 지원하는지 확인하고, 앱 ZIP과 함께 게시된 SHA256SUMS.txt를 다운로드한 다음 설치 전에 체크섬을 검증해 줘. 실행 중인 SwitchGPT가 있으면 종료하고 /Applications에 설치한 뒤 실행해 줘. 기존에 저장된 계정과 키체인 항목은 모두 보존해 줘. 대신 로그인하거나 계정을 전환하지는 마. macOS가 첫 실행을 차단하면 시스템 보안 설정을 비활성화하지 말고 Apple의 앱별 '확인 없이 열기' 절차를 안내해 줘.
```

로컬 도구를 사용할 수 없다면 위의 수동 설치 방법을 이용하세요.

### 첫 실행

배포본은 **ad-hoc 서명**을 사용하며 **Apple 공증을 받지 않았습니다**. macOS가 실행을 차단하면 의도한 릴리스를 다운로드했는지 확인하고 앱 실행을 시도한 뒤, 해당 옵션이 나타나는 경우 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**를 사용하세요. [알 수 없는 개발자의 앱을 여는 Apple 안내](https://support.apple.com/en-ca/guide/mac-help/mh40616/mac)를 참고하세요. 조직에서 관리하는 Mac에서는 이 예외 허용이 제한될 수 있습니다.

릴리스에는 `SHA256SUMS.txt`도 포함되어 있습니다. 두 파일을 같은 폴더에 다운로드한 뒤 다음 명령으로 압축 파일을 검증할 수 있습니다.

```sh
shasum -a 256 -c SHA256SUMS.txt
```

### 업데이트

메뉴 막대 패널에서 SwitchGPT를 종료하고, 응용 프로그램 폴더의 앱을 새 버전으로 교체한 뒤 다시 실행하세요. 저장된 계정 목록과 키체인 항목은 앱 번들 외부에 보관됩니다.

## 사용 방법

1. **계정 추가:** 저장할 계정마다 브라우저 로그인을 완료합니다. 이메일은 로그인 정보에서 읽습니다.
2. **새로 고침:** 새로 고침 버튼으로 현재 사용량과 초기화 가능 횟수를 조회합니다.
3. **전환:** 진행 중인 ChatGPT 작업을 마친 뒤 다른 계정 카드를 클릭하고 재시작을 확인합니다. 현재 계정을 클릭하면 전환하지 않습니다.
4. **순서 변경:** 계정 카드를 다른 카드 위로 드래그해 저장 순서를 바꿉니다.
5. **삭제:** 휴지통 아이콘을 누르고 저장 목록에서 삭제를 확인합니다. OpenAI 계정 자체를 삭제하는 기능은 아닙니다.

계정 카드에는 사용 가능한 프로필 사진이 표시됩니다. 연필 아이콘으로 표시 이름을 바꾸고, 빈칸으로 저장하면 이메일로 돌아갑니다. 상단에는 새로 고침, **+**(계정 추가), 전원(종료) 아이콘이 있습니다. 앱 실행 중에는 패널을 닫아도 조회 완료 후 60초마다 자동으로 갱신하며, 로그인·계정 전환 중이거나 조회가 진행 중이면 건너뜁니다.

사용 한도 초기화 영역은 **조회 전용**입니다. SwitchGPT에서 초기화를 사용하거나 소모하지 않습니다.

언어 변경은 앱을 다시 열면 적용됩니다. 앱 내부의 언어 선택 메뉴는 제공하지 않습니다.

## 소스에서 빌드

Swift 6와 macOS SDK가 포함된 Xcode를 설치하고 해당 명령줄 도구를 선택한 뒤 실행하세요.

```sh
git clone https://github.com/yoonpooh/SwitchGPT.git
cd SwitchGPT
./script/build_and_run.sh --verify
```

`dist/SwitchGPT.app`에 로컬 앱을 빌드하고 ad-hoc 서명 후 실행하여 프로세스가 실행 중인지 확인합니다. 응용 프로그램 폴더에 자동 설치하지는 않습니다. 직접 빌드한 앱을 설치하려면 SwitchGPT를 종료하고 Finder에서 생성된 앱을 응용 프로그램 폴더로 옮기세요.

사용 가능한 명령:

```sh
./script/build_and_run.sh           # 디버그 앱 빌드 및 실행
./script/build_and_run.sh --verify  # 빌드·실행 후 프로세스 확인
./script/build_and_run.sh --build   # 실행하지 않고 디버그 앱 빌드
./script/build_and_run.sh --release # 실행하지 않고 최적화된 앱 빌드
swift test                         # 테스트 실행
```

가능하면 저장소를 iCloud Drive 외부에 두세요. 동기화 폴더에서 Finder 정보 또는 리소스 포크 관련 코드 서명 오류가 발생하면 별도 빌드 경로로 테스트하세요.

```sh
swift test --scratch-path /tmp/switchgpt-tests
```

### 릴리스 패키징

스크립트는 빌드하는 Mac의 아키텍처를 대상으로 합니다. 공개된 v0.1.5 파일은 Apple silicon 빌드입니다.

```sh
./script/build_and_run.sh --release
ditto -c -k --norsrc --keepParent dist/SwitchGPT.app dist/SwitchGPT-v0.1.5-macos-arm64.zip
(cd dist && shasum -a 256 SwitchGPT-v0.1.5-macos-arm64.zip > SHA256SUMS.txt)
```

## 데이터와 호환성

| 데이터 | 저장 위치 |
| --- | --- |
| 저장된 로그인 정보 | macOS 키체인 (SwitchGPT에서 관리) |
| 계정 목록과 순서 | `~/Library/Application Support/SwitchGPT/accounts.json` |
| 현재 데스크톱 인증 정보 | `~/.codex/auth.json` |

0.1.3은 새 계정 목록이 없는 경우 첫 실행 시 이전 저장 위치의 목록을 복사합니다. 원본 파일과 기존 키체인 항목은 그대로 보존합니다.

전환 전에 현재 로그인 정보를 저장하고, `0600` 권한의 임시 파일을 사용해 활성 인증 파일을 교체합니다. ChatGPT 재시작에 실패하면 이전 인증 정보 복구를 시도하고, 복구 실패도 표시합니다.

사용량은 OpenAI의 비공개 `chatgpt.com/backend-api/wham/` 엔드포인트에서 직접 조회합니다. 별도의 SwitchGPT 백엔드는 없습니다. 해당 엔드포인트와 데스크톱 앱의 로컬 서버 동작은 변경될 수 있으며, 인증 정보가 만료되면 다시 로그인해야 할 수 있습니다. 로컬 재시작 성공만으로 서버가 새 세션을 수락했다고 확인할 수는 없습니다.

현재 제한 사항:

- API 키 인증, keyring/auto 인증 저장 방식, 사용자 지정 `CODEX_HOME`, 원격 호스트는 지원하지 않습니다.
- 자동 계정 전환과 내장 업데이트 기능은 없습니다.
- 전환은 데스크톱 앱의 로컬 서버를 공유하는 CLI 세션에도 영향을 줄 수 있습니다. 진행 중인 작업을 마친 뒤 전환하세요.
- 사용량이나 만료 정보가 없으면 0으로 표시하지 않고 확인 불가로 표시합니다.
- 빌드 성공이 모든 ChatGPT 데스크톱 버전이나 지원 대상 macOS 버전과의 호환성을 보장하지는 않습니다.

이슈나 커밋에 인증 정보, 계정 목록, 개인 계정이 보이는 스크린샷을 포함하지 마세요.

## 소스 구조

```text
Assets/                         앱 및 메뉴 막대 아이콘
Sources/SwitchGPT/
  App/                          메뉴 막대 앱 진입점
  Models/                       계정·사용량 모델과 다국어 처리
  Resources/                    영어·한국어·중국어·일본어 문구
  Services/                     로그인·키체인·사용량·데스크톱 세션 처리
  Stores/                       계정 상태와 순서
  Views/                        계정 패널과 사용량 표시
Tests/SwitchGPTTests/   인증·로그인·서버·순서·다국어 테스트
script/build_and_run.sh          빌드 및 앱 패키징 진입점
```

테스트는 가짜 인증 정보와 임시 파일을 사용하며, 실제 계정을 전환하거나 사용 한도 초기화를 소모하지 않습니다. 실제 로그인과 서버 호환성은 별도로 검증해야 합니다.
