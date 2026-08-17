# dc-vps

iPhone LiDAR 기반 VPS(Visual Positioning Service) 자체 구축 프로젝트.
NAVER ARC eye와 동일한 개념(사전 스캔 맵에 쿼리 이미지를 매칭해 6DoF pose를 리턴하는
localization-against-prebuilt-map 방식)을 [hloc](https://github.com/cvg/Hierarchical-Localization)
기반으로 자체 내재화한다.

## 배경

- ARKit VIO는 시간이 지나면 drift가 누적된다. 절대좌표계 맵에 매칭하는 VL(재측위) 방식은
  drift-free한 절대 pose를 얻을 수 있어 로봇 pose 추정에 유리하다.
- iPhone LiDAR로 얻는 depth는 metric scale이 확정되어 있으므로, 일반 monocular SfM(COLMAP
  삼각측량)이 필요 없다. hloc의 InLoc 파이프라인처럼 "스캔 시점의 depth에서 2D keypoint의
  3D 좌표를 직접 backproject"하는 방식을 쓴다.

## 아키텍처

```
[매핑]
iPhone (ios-capture 앱)
  → RGB + LiDAR sceneDepth + confidence + ARKit pose(6DoF) + intrinsics 캡처
  → scan_<name>/ 폴더로 export (rgb/, depth/, poses/poses.jsonl)

[DB 빌드] (pipeline/)
scan 폴더
  → SuperPoint(local feature) + NetVLAD(global descriptor) 추출 (hloc.extract_features)
  → keypoint(RGB 좌표) → depth 해상도로 스케일 다운 → nearest-neighbor depth/confidence lookup
  → confidence < medium 또는 depth 범위 밖이면 버림
  → intrinsics로 backproject → ARKit pose로 world 좌표 변환
  → keypoint별 3D 좌표 테이블(DB) 확보 (COLMAP 삼각측량 불필요)

[로컬라이제이션 서버] (server/)
쿼리 이미지 + intrinsics 수신
  → SuperPoint + NetVLAD 추출 (hloc.extract_features 재사용)
  → NetVLAD 코사인 유사도로 DB 후보 top-k 검색
  → LightGlue로 2D-2D 매칭 → 대응하는 3D 좌표 확보 (kp_to_3d_db.pkl)
  → PnP+RANSAC (pycolmap.estimate_and_refine_absolute_pose) → 6DoF pose
  → JSON으로 리턴

[로봇/Nav2 통합] (ros2_ws/src/dc_vps_bridge/)
로봇 카메라 토픽을 주기적으로 서버에 쿼리 → 리턴된 pose를 map 프레임으로 캘리브레이션
변환 → PoseWithCovarianceStamped 퍼블리시. robot_localization EKF의 한 입력 소스로
fusion하거나, amcl `/initialpose`로 remap해서 재측위에 사용.
hloc world 좌표계와 occupancy grid 좌표계는 최초 스캔 시 origin 캘리브레이션으로 정합한다.
```

## 폴더 구조

```
dc-vps/
├── ios-capture/                   # ARKit 캡처 앱 (Swift, Xcode에서 열어서 사용)
├── pipeline/                      # DB 빌드 파이프라인 (Python, hloc 기반)
├── server/                        # FastAPI 로컬라이제이션(VL) 서버
├── ros2_ws/src/dc_vps_bridge/     # ROS2(Humble) Nav2 연동 브리지 노드
└── data/                          # 스캔 데이터 (git에 커밋하지 않음)
```

## 정합(depth-RGB alignment) 핵심 규칙

- iPhone LiDAR: RGB 1920×1440, depth/confidence 256×192 (종횡비 동일, 4:3).
- keypoint를 depth 해상도로 스케일 다운해서 lookup한다 (반대 방향인 depth upsampling은 하지 않음).
- depth lookup은 반드시 nearest-neighbor. bilinear는 물체 경계에서 "flying pixel" 아티팩트를 만든다.
- confidence map으로 low-confidence 포인트는 버린다 (반사면/저텍스처 영역 대응).
- 저장 단계에서는 회전 보정을 하지 않고 raw(landscape) 방향 그대로 저장한다. intrinsics도
  raw 기준이므로 임의로 회전시키면 cx/cy가 어긋난다. 회전 처리가 필요하면 Python DB 빌드
  단계에서 일괄 처리한다.

## 현재 상태

- [x] 아키텍처 설계
- [x] 프로젝트 스캐폴딩
- [x] ios-capture 앱 구현 (Xcode 프로젝트 포함, 실기기 빌드·스캔까지 검증 완료)
- [x] pipeline DB 빌드 스크립트 구현/검증 (실제 스캔 데이터로 end-to-end 검증 완료)
- [x] server FastAPI 쿼리 서버 구현 (`/localize` 구현 + 실데이터/실사진 검증 완료,
      모델 캐싱으로 쿼리당 30초~1분 → 10~20초대로 개선)
- [ ] Nav2/robot_localization 통합 (`ros2_ws/src/dc_vps_bridge/` — macOS pixi/RoboStack로
      ROS2 Humble 설치 후 colcon build/ros2 launch까지 실제 검증 완료. 로봇/카메라/Nav2
      스택이 없어 실제 이미지 토픽으로 VPS 쿼리하는 end-to-end 흐름은 미검증)
