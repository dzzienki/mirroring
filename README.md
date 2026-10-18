# 무선 셀카 모니터 (Wireless Selfie Viewfinder) 📸✨

갤럭시(메인 폰)의 기본 카메라 화면을 아이폰/갤럭시(서브 폰)로 실시간 스트리밍하여 고화질 후면 카메라 셀카 및 원격 촬영을 도와주는 초저지연 무선 뷰파인더 시스템입니다.

아이폰에 별도의 앱 설치나 애플 개발자 계정($99/년) 등록 없이, **사파리(Safari) 웹/PWA**를 통해 즉시 뷰파인더로 동작합니다.

---

## 🌟 주요 특징

1. **데이터 0원 & 와이파이 불필요 (핫스팟 다이렉트 연결)**
   - LTE/5G 데이터 소모 없이 메인 폰의 모바일 핫스팟 또는 로컬 Wi-Fi를 통해 직접 P2P로 스트리밍됩니다.
2. **초저지연 뷰파인더 스트리밍 (< 50ms)**
   - 안드로이드 네이티브 `MediaProjection` + 하드웨어 제로카피 버퍼 정렬(512px) + 고속 JPEG 압축(26 FPS).
   - 대역폭을 ~5 Mbps로 최적화하여 Wi-Fi 소켓 과부하 및 발열 없이 부드러운 프리뷰 제공.
3. **삼성 기본 카메라 원격 셔터 연동**
   - 안드로이드 접근성 서비스(`CameraAccessibilityService`)를 통해 서브 폰 웹 화면의 원격 셔터 버튼을 누르면 갤럭시의 기본 카메라 셔터 버튼이 물리적으로 자동 클릭됩니다.
4. **강력한 뷰파인더 편의 기능**
   - 📱 **화면 가득 채우기 (Full Screen)**: 블랙바 없이 서브 폰 화면 100% 꽉 채움.
   - 🪞 **거울 모드 (Mirror Toggle)**: 거울처럼 좌우 반전 뷰 지원.
   - 🔄 **90° 단위 회전**: 가로/세로 촬영에 맞게 원터치 0°/90°/180°/270° 회전.
   - ⏱️ **타이머 촬영**: 3초/5초/10초 카운트다운 타이머.
   - 👁️ **클린 UI (HUD 숨김)**: 화면을 터치하여 뷰파인더 UI를 숨기고 프리뷰만 깔끔하게 확인.
5. **완벽한 상태 머신 & 대기화면**
   - 미러링 중지 시 잔여 화면 멈춤 없이 즉시 `⏸️ 화면 미러링 중지됨` 대기화면으로 자동 전환.
   - 다중 펄스 통지 및 프레임 워치독(Watchdog)으로 연결 안정성 100% 보장.

---

## 🚀 빠른 시작 가이드

### 1. 메인 폰 (갤럭시)
1. 앱 빌드 및 설치:
   ```bash
   flutter build apk --release
   adb install -r build/app/outputs/flutter-apk/app-release.apk
   ```
2. 앱 실행 후 **[접근성 권한 켜기]**를 눌러 "무선 셀카 모니터" 접근성 서비스를 활성화합니다. (원격 촬영용)
3. **[🚀 화면 미러링 시작]**을 누르고 전체 화면 공유를 승인합니다.
4. 화면의 **[📷 삼성 기본 카메라 열기]**를 누르면 고화질 후면 카메라가 열립니다.

### 2. 서브 폰 (아이폰 / 기타 스마트폰)
1. 메인 폰의 핫스팟 또는 동일한 Wi-Fi에 연결합니다.
2. 카메라 앱으로 메인 폰 화면에 표시된 **QR 코드**를 스캔하거나 브라우저 주소창에 `http://<갤럭시-IP>:8080`을 입력하여 접속합니다.
3. 홈 화면에 추가(PWA)하면 전체화면 네이티브 앱처럼 사용할 수 있습니다.

---

## 🛠️ 기술 스택

- **Host App**: Flutter 3.x, Android Native (Kotlin)
  - `MediaProjection` (실시간 화면 캡처)
  - `ImageReader` & `Hardware Canvas` (256-byte aligned zero-copy)
  - `CameraAccessibilityService` (카메라 앱 UI 제어)
  - Shelf HTTP & WebSocket Server (`shelf_web_socket`)
- **Remote Viewfinder**: Modern Web & PWA
  - Vanilla JS, Hardware-accelerated `createImageBitmap`
  - HTML5 Canvas, Screen WakeLock API
