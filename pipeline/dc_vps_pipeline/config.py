"""공장 실내 스캔 기준으로 잡은 기본값. 환경에 따라 조정."""

# iPhone LiDAR 해상도 (RGB, depth/confidence) — 종횡비 동일(4:3)이므로 스케일은 1축으로 충분
RGB_WIDTH = 1920
RGB_HEIGHT = 1440
DEPTH_WIDTH = 256
DEPTH_HEIGHT = 192

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

# server/app/localize.py: PnP+RANSAC inlier가 이 값 미만이면 로컬라이제이션 실패로 처리
MATCHER_CONF = "superpoint+lightglue"
MIN_INLIERS = 12
