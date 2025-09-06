# Ubuntu APT Mirror Changer

우분투 APT 미러를 쉽게 변경할 수 있는 대화형 스크립트입니다. 국내 미러(카이스트, 카카오)와 우분투 공식 미러를 지원하며, 속도 측정을 통해 가장 빠른 미러를 자동으로 추천합니다.

## 설치 및 실행

### 방법 1: GitHub에서 직접 실행 (권장)
```bash
wget -O apt-mirror-changer.sh https://raw.githubusercontent.com/i1hwan/apt-mirror-changer/main/apt-mirror-changer.sh && sudo bash apt-mirror-changer.sh
```

### 방법 2: 로컬에서 실행
1. 저장소 클론:
   ```bash
   git clone https://github.com/i1hwan/apt-mirror-changer.git
   cd apt-mirror-changer
   ```

2. 실행 권한 부여:
   ```bash
   chmod +x apt-mirror-changer.sh
   ```

3. 실행:
   ```bash
   sudo ./apt-mirror-changer.sh
   ```

## 사용법

### 대화형 모드 (기본)
스크립트 실행 후 whiptail 메뉴가 나타납니다:

1. **속도 측정**: 각 미러의 다운로드 속도를 측정합니다 (약 10-30초 소요, 단일 파일 테스트).
2. **미러 선택**:
   - **가장 빠른 미러**: 자동으로 가장 빠른 미러 선택
   - **수동 선택**: 목록에서 원하는 미러 선택 (성공: 속도 표시, 실패: "실패" 표시)
   - **복원**: 백업 파일에서 설정 복원
3. **변경 및 검증**: 선택한 미러로 변경 후 `apt update`로 검증
4. **실패 처리**: 검증 실패 시 자동 복원 옵션 제공

## 옵션 설명

- `--no-interactive`: 비대화형 모드로 실행
- `--debug`: 내부 속도 측정/진행 상황 디버그 로그를 stderr 로 출력

## 기여

1. Fork 후 Pull Request
2. 이슈 보고: 버그나 기능 제안

## 라이선스

MIT License

## 개발자
[i1hwan](https://github.com/i1hwan)
