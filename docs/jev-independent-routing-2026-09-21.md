# 모델·추론 수준 독립 라우팅 — 로컬 후보

## 범위

v0.2.5 (`3eaf606`)의 압축 요청 처리를 기반으로 모델과 추론 수준을 독립적으로 선택하는 로컬 변경이다. 초기 검증은 앱 설치·실계정 호출 없이 진행했다. 이후 사용자 요청에 따른 설치와 실사용 진단은 [effort 보완 기록](effort-routing-fix-2026-09-21.md)에 구분했다.

참고한 구현은 [Claude Code Templates의 Jev 모듈](https://github.com/davila7/claude-code-templates/tree/9f5d843b72ff9a0af12b5c4b0a2cf7118b88f833/cli-tool/components/mods/productivity/jev-model-router)이다. Claude 전용 hook이나 backend fallback을 이식하지 않고, 독립 설정과 방향별 판단 기준을 SwitchGPT의 기존 릴레이에 적용한다.

## 정책

- 모델 자동 선택과 추론 수준 자동 선택을 각각 저장한다. 새 설정에서는 둘 다 OFF다.
- 구버전 파일에 `effortAutomatic`이 없으면 `modelAutomatic` 값을 상속한다. 기존 단일 스위치가 두 항목을 함께 변경하던 동작을 보존한다.
- 한 항목만 켜면 다른 항목은 요청의 원래 값을 유지한다. 지원하지 않는 최종 조합을 만들어 전송하지 않는다.
- 자동 선택은 Luna/Sol/Astra 각각 medium/high/max를 허용한다. Codex 0.155.0의 모델 capability 캐시(2026-09-20 UTC 갱신)에서 지원을 확인했다. 기존 low 값은 보존하거나 confidence를 충족하면 상향할 수 있다. xhigh/ultra와 생략된 추론 수준은 임의로 재작성하지 않는다.
- KEEP, privacy 검사, 명시적 서브에이전트 선택, 턴별 재사용, 설정 변경 무효화, 압축 원본 fallback을 유지한다.
- 상향·하향 confidence 기준을 분리한다. 후속 실사용 진단을 반영한 현재 기준은 effort 상향 0.65, effort 하향과 모델 변경 0.8이다. `confidence`는 실제 작업 성공 확률이 아니다.
- 방향을 판단할 수 있는 기준 모델은 Luna/Sol/Astra다. 이전의 넓은 `gpt-5*`/`codex` 이름 검사를 줄여, 순위를 모르는 구형·다른 모델은 외부 분류 없이 유지한다. 알 수 없는 추론 수준도 자동으로 낮추지 않는다.

## 기존 표본의 임계값 민감도

실행 명령:

```sh
python3 script/evaluate_routing_thresholds.py /tmp/switchgpt-router-goal
```

기존 60건의 결합 Choice 결과를 재사용했다. 어느 한 항목이라도 하향이면 하향 기준을 적용한 **옛 결합 정책의 민감도 검사**다. 새 분리 질문의 독립 confidence나 분류 정확도 검증이 아니다. API 호출과 원문 출력은 없다.

| 상향 / 하향 | 승인 | 허용 라벨 일치 | KEEP 위반 | 조합 변경 |
| --- | ---: | ---: | ---: | ---: |
| 0.8 / 0.8 | 38 | 37 | 0 | 31 |
| 0.65 / 0.85 | 38 | 37 | 0 | 31 |
| 0.8 / 0.85 | 38 | 37 | 0 | 31 |
| 0.8 / 0.9 | 36 | 35 | 0 | 29 |

이 옛 결합 표본만으로는 임계값을 바꿀 이점이 확인되지 않아 초기 분리 구현은 0.8을 유지했다. 이후 분리 질문의 실사용 진단을 반영한 effort 상향 기준 조정은 `effort-routing-fix-2026-09-21.md`에 별도로 기록했다. 새 질문은 선택지 수와 의미가 바뀌므로 동일 수치라도 이전 정책과 같은 동작률을 보장하지 않는다. 새 분류 품질·지연은 별도의 고정 표본으로 실 API 평가가 필요하다.

입력 파일 SHA-256:

- `scored.json`: `2fdd2433f35dccc0722c6aaf053f71ca67b7402b5752a841a9839f83a77f97e4`
- `cases.json`: `fb624cccc3d7b17989bdb537380d6d458120d5ce99a84834e7e1b10d7c99e2a2`

표본 원문은 저장소에 복사하지 않았다. 위 임시 디렉터리는 영구 보존을 보장하지 않는다.

## 검증 상태

- `swift test`: 110개 통과, 실패 0. 독립 모델/effort 변경, confidence별 보존, 전역 KEEP, 잘못된 확률분포, 지원 조합 거부 사유, 설정 마이그레이션·저장 실패, 압축 요청·계정 재시도를 포함한다.
- `swift build`와 `git diff --check` 통과. 독립 코드 검토의 지적을 반영했다.
- 실제 `AccountPanel`을 임시 검증 앱에서 열어 effort만 ON → 둘 다 ON → 모델만 ON 상태를 클릭하고, 격리된 설정 파일의 저장 값과 대조했다. 임시 앱은 종료했다. 실제 계정·키체인·설치된 앱은 사용하지 않았다.
- UI 도구가 화면 캡처를 제공하지 않아 접근성 메뉴 정보와 실제 클릭·저장 결과로 검증했다. 픽셀 단위 화면 검증은 하지 않았다.
- `graphify update .`를 로컬 비과금 코드 추출 경로로 실행했다. 956 nodes / 2,561 edges로 갱신됐으나, 기존 `ModelRoutingTests.swift:132`의 파서 경고로 해당 파일은 부분 추출될 수 있다. Swift 컴파일 실패는 아니다.
- 실 Jev 호출, 새 분리 질문의 분류 정확도·실 API 호환성, 설치 앱의 실제 Codex 요청은 검증하지 않았다.
