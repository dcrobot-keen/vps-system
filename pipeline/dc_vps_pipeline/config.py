"""공장 실내 스캔 기준으로 잡은 기본값. 환경에 따라 조정.

server/도 이 모듈을 그대로 import해서 쓴다 (pip install -e ../pipeline, server/README.md
참고) — DB가 이 설정으로 빌드되기 때문에 쿼리 쪽(server)도 같은 설정을 써야 keypoint
좌표계/디스크립터가 호환된다. 이 값들을 바꾸면 기존 DB를 다시 빌드해야 한다.
"""

# iPhone LiDAR 해상도 (RGB, depth/confidence) — 종횡비 동일(4:3)이므로 스케일은 1축으로 충분.
# RGB_WIDTH/HEIGHT는 poses.jsonl에 intrinsics.width/height가 없는 옛 레코드의 폴백일 뿐이다 --
# 2026-09-05부터 앱은 RGB를 1600x1200으로 저장하고 레코드에 그 크기를 적으므로,
# 실제 배율은 geometry.depth_scale(frame.image_size)로 프레임마다 구한다.
RGB_WIDTH = 1920
RGB_HEIGHT = 1440
DEPTH_WIDTH = 256
DEPTH_HEIGHT = 192

# 옛 이름 유지(외부 스크립트 호환). 새 코드는 geometry.depth_scale(image_size)를 쓸 것.
SCALE_X = DEPTH_WIDTH / RGB_WIDTH
SCALE_Y = DEPTH_HEIGHT / RGB_HEIGHT

# ARConfidenceLevel: 0=low, 1=medium, 2=high (Apple 문서 기준 실제 값은 기기별로 확인 필요)
MIN_CONFIDENCE = 1  # medium 이상만 사용

# 공장 실내 스캔 기준 5m 초과 depth는 LiDAR 신뢰도 급감
MAX_DEPTH_METERS = 5.0
MIN_DEPTH_METERS = 0.0

# InLoc 설정 재사용 (반복 패턴 많은 공장 실내에 최적화됨)
SUPERPOINT_CONF = "superpoint_inloc"  # max_keypoints=4096, nms_radius=4, resize_max=1600
RETRIEVAL_CONF = "netvlad"
RETRIEVAL_TOP_K = 20

# server 전용 (pipeline은 매칭을 안 하지만, hloc 관련 설정을 한곳에 모아두기 위해 여기 둔다)
MATCHER_CONF = "superpoint+lightglue"

# export_pointcloud.py: 프레임 간 겹치는 depth 포인트를 한 점으로 합칠 복셀 크기.
# scan-to-map-studio의 기본 occupancy grid 해상도(5cm/cell)보다 촘촘하게 잡았다.
POINTCLOUD_VOXEL_SIZE_METERS = 0.03
