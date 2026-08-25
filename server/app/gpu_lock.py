"""GPU가 물리적으로 하나뿐이라, DB 빌드(scan_jobs.py, pipeline.db_build)와
실시간 쿼리(localize.py의 SuperPoint/NetVLAD/LightGlue forward pass)가 동시에
같은 CUDA 컨텍스트를 건드리지 않게 이 lock으로 직렬화한다.

localize.py 쪽은 메서드 전체가 아니라 실제 torch.no_grad() 구간만 감싼다 —
PnP+RANSAC(CPU, 병목의 대부분)은 빌드가 lock을 쥐고 있어도 계속 돌 수 있게
두는 게 낫다. scan_jobs.py 쪽은 db_build.build_db() 호출 전체를 감싼다(그
안이 사실상 전부 GPU 작업이라 더 잘게 쪼갤 실익이 없고, pipeline 코드를
건드리지 않고 서버 쪽에서만 통제하기 위함).
"""

import threading

GPU_LOCK = threading.Lock()
