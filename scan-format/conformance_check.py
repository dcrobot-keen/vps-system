#!/usr/bin/env python3
"""scan_<name>/ 폴더가 SCAN_FORMAT.md 스펙을 지키는지 확인한다.

정본은 vps-system/scan-format/ -- 다른 저장소(dc-vps-digital-twin,
scan-to-map-studio)의 scan-format/ 폴더는 이 사본이다. 스펙이 바뀌면 여기를
먼저 고치고 나머지 저장소에 수동으로 복사한다(architecture-improvements.md
④ 참고 -- git submodule 대신 의도적 복사+컨벤션을 택한 이유가 적혀 있다).

Usage: python conformance_check.py <scan_dir>
"""
import json
import sys
from pathlib import Path

try:
    import jsonschema
except ImportError:
    sys.exit("jsonschema 패키지가 필요합니다: pip install jsonschema")

HERE = Path(__file__).parent
MANIFEST_SCHEMA = json.loads((HERE / "manifest.schema.json").read_text(encoding="utf-8"))
POSE_SCHEMA = json.loads((HERE / "pose-record.schema.json").read_text(encoding="utf-8"))

# poses.jsonl이 가리키는 .depth 파일의 실제 크기 검증용. 이 (192, 256) 크기는
# 세 Python 소비자 전부에 각자 하드코딩돼 있고 manifest.json/poses.jsonl
# 어디에도 명시적으로 기록되지 않는다 -- SCAN_FORMAT.md의 "알려진 취약점"
# 참고. 다른 기기가 다른 LiDAR 해상도를 쓰게 되면 이 상수부터 확인할 것.
DEPTH_HEIGHT, DEPTH_WIDTH = 192, 256
DEPTH_BYTES = DEPTH_HEIGHT * DEPTH_WIDTH * 4  # float32


def check(scan_dir: Path) -> list[str]:
    errors = []

    manifest_path = scan_dir / "manifest.json"
    if not manifest_path.exists():
        errors.append(f"manifest.json 없음: {manifest_path}")
    else:
        try:
            jsonschema.validate(json.loads(manifest_path.read_text(encoding="utf-8")), MANIFEST_SCHEMA)
        except json.JSONDecodeError as e:
            errors.append(f"manifest.json이 유효한 JSON이 아님: {e}")
        except jsonschema.ValidationError as e:
            errors.append(f"manifest.json 스키마 위반: {e.message}")

    poses_path = scan_dir / "poses" / "poses.jsonl"
    if not poses_path.exists():
        errors.append(f"poses.jsonl 없음: {poses_path}")
    else:
        lines = [l for l in poses_path.read_text(encoding="utf-8").splitlines() if l.strip()]
        if not lines:
            errors.append("poses.jsonl이 비어 있음")
        for i, line in enumerate(lines, start=1):
            try:
                record = json.loads(line)
                jsonschema.validate(record, POSE_SCHEMA)
            except json.JSONDecodeError as e:
                errors.append(f"poses.jsonl {i}번째 줄이 유효한 JSON이 아님: {e}")
                continue
            except jsonschema.ValidationError as e:
                errors.append(f"poses.jsonl {i}번째 줄 스키마 위반: {e.message}")
                continue

            for key in ("rgb_path", "depth_path"):
                p = scan_dir / record[key]
                if not p.exists():
                    errors.append(f"poses.jsonl {i}번째 줄이 가리키는 {key} 파일 없음: {p}")

            depth_path = scan_dir / record["depth_path"]
            if depth_path.exists():
                size = depth_path.stat().st_size
                if size != DEPTH_BYTES:
                    errors.append(
                        f"{depth_path} 크기가 {size}바이트, 예상 {DEPTH_BYTES}바이트"
                        f"({DEPTH_HEIGHT}x{DEPTH_WIDTH} float32)와 다름"
                    )
                conf_path = depth_path.with_suffix(".conf")
                if not conf_path.exists():
                    errors.append(f"{depth_path}의 짝인 .conf 파일 없음: {conf_path}")

    if not (scan_dir / "scan.usdz").exists():
        errors.append(f"scan.usdz 없음: {scan_dir / 'scan.usdz'}")

    return errors


if __name__ == "__main__":
    # Windows 콘솔은 stdout 기본 인코딩이 UTF-8이 아닐 수 있다(cp949 등) --
    # 한글 출력이 깨지는 걸 막는다.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if len(sys.argv) != 2:
        sys.exit(f"Usage: python {sys.argv[0]} <scan_dir>")
    target = Path(sys.argv[1])
    problems = check(target)
    if problems:
        print(f"FAIL ({len(problems)}개 문제) -- {target}")
        for p in problems:
            print(f"  - {p}")
        sys.exit(1)
    print(f"OK: {target}가 scan_<name>/ 포맷을 따릅니다")
