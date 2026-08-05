# AudioWaterfall

SGI IRIX의 클래식 데모 **amesh**에서 영감을 받은 macOS용 실시간 3D 스펙트럼 워터폴 시각화 앱입니다. 오디오를 실시간으로 FFT 분석해서, 시간축을 따라 겹겹이 쌓이는 3D 와이어프레임 "산맥" 형태로 보여줍니다.

Swift + SwiftUI + SceneKit + Accelerate(vDSP)로 작성되었으며, Apple Silicon Mac(M1 등)에서 동작합니다.

## 주요 기능

- **3가지 오디오 입력 소스**
  - 마이크 / 라인인 실시간 입력
  - 오디오 파일 재생 분석 (파일을 직접 재생하면서 동시에 시각화)
  - 시스템 오디오 캡처 (ScreenCaptureKit 기반 — 다른 앱이 재생 중인 소리를 그대로 분석)
- **3D 와이어프레임 워터폴 렌더링** (SceneKit)
  - 마우스 드래그로 카메라 자유 회전
  - 주파수축 방향 선(가로선)만 표시하는 amesh 스타일의 클래식 룩
- **5가지 슈도컬러 컬러맵**: Turbo, Grayscale, Purple(Plasma 스타일), Fire(Inferno 스타일), Viridis
- **배경색 선택**: 검정 / 진보라 / 백색 / 진녹색 / 암적색
- **스펙트럼 해상도 선택**: Low(32) ~ Ultra(512) 빈(bin) 개수 중 선택
- **로그 스케일 / 저주파(스무딩) 필터** 켜고 끄기
- **자동 게인(AGC)**: 입력 소스의 절대적인 음량 차이와 무관하게 색상·높이 범위가 자동으로 맞춰짐

## 요구 사항

- macOS 14.0 이상
- Apple Silicon Mac (M1 이상 권장)
- Xcode 16 이상

## 빌드 및 실행

```bash
xcodebuild -project AudioWaterfall.xcodeproj -scheme AudioWaterfall build
```

또는 Xcode에서 `AudioWaterfall.xcodeproj`를 열고 Cmd+R로 실행합니다. 마이크/화면 녹화 권한 요청 창은 앱을 포그라운드에서 직접 실행해야 뜨므로, 최초 실행은 Xcode(또는 Finder에서 직접 실행)로 하는 것을 권장합니다.

### 권한 관련 참고 사항

- **마이크**: 최초 마이크 소스 사용 시 시스템 권한 요청이 뜹니다.
- **시스템 오디오**: macOS의 "화면 및 시스템 오디오 녹화" 권한이 필요합니다. 권한을 처음 허용한 직후에는 앱을 재실행해야 캡처가 정상 동작하는 경우가 있습니다 (ScreenCaptureKit의 알려진 특성).

## 아키텍처 개요

| 파일 | 역할 |
|---|---|
| `AudioSource.swift` | 오디오 입력 소스 공통 프로토콜 |
| `MicrophoneAudioSource.swift` / `FileAudioSource.swift` / `SystemAudioSource.swift` | 각 입력 소스 구현체 |
| `AudioFormatConverter.swift` | 서로 다른 입력 포맷을 표준 포맷(모노 Float32 44.1kHz)으로 변환 |
| `SpectrumAnalyzer.swift` | vDSP 기반 FFT 파이프라인 (윈도잉, FFT, dB 변환, 로그스케일, 스무딩, 다운샘플링) |
| `SpectrumHistory.swift` | 시간축 스펙트럼 이력을 담는 링 버퍼 |
| `Colormap.swift` | 진폭 → RGB 슈도컬러 매핑 |
| `WaterfallSceneView.swift` | SceneKit 기반 3D 와이어프레임 메시 렌더링 |
| `AppViewModel.swift` | 오디오 소스 전환, 상태 관리, UI와 분석 파이프라인 연결 |
| `ContentView.swift` | SwiftUI 툴바 및 메인 화면 |

## 배경

IRIX의 `amesh`는 오디오를 FFT로 분석해 3D 스펙트럼 워터폴로 보여주면서, 동시에 SGI 워크스테이션의 실시간 신호처리 능력과 3D 그래픽 파이프라인을 함께 과시하던 데모였습니다. 이 프로젝트는 그 아이디어를 현대 macOS(Apple Silicon)에서 Swift/SceneKit으로 재현한 것입니다.
