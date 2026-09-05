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

# v1 스캔(manifest에 depth_encoding 없음)의 depth 해상도. v1에서는 이 크기가 세 Python
# 소비자에 각자 하드코딩돼 있고 어디에도 기록되지 않는다 -- v2부터는 manifest의
# depth_encoding.width/height가 정본이다(SCAN_FORMAT.md "depth/*.depth" 참고).
DEPTH_HEIGHT, DEPTH_WIDTH = 192, 256
BYTES_PER_SAMPLE = {"float32_m": 4, "float32": 4, "uint16_mm": 2, "uint8": 1}


def expected_frame_bytes(manifest: dict | None) -> tuple[int, int, str]:
    """(depth 파일 크기, conf 파일 크기, 설명) -- manifest의 depth_encoding에 따라."""
    enc = (manifest or {}).get("depth_encoding")
    if not enc:
        n = DEPTH_HEIGHT * DEPTH_WIDTH
        return n * 4, n * 4, f"v1 {DEPTH_HEIGHT}x{DEPTH_WIDTH} float32/float32"
    n = int(enc["height"]) * int(enc["width"])
    d, c = enc["depth"], enc["confidence"]
    if d not in BYTES_PER_SAMPLE or c not in BYTES_PER_SAMPLE:
        raise ValueError(f"알 수 없는 depth_encoding: depth={d!r} confidence={c!r}")
    return n * BYTES_PER_SAMPLE[d], n * BYTES_PER_SAMPLE[c], f"v{enc.get('format_version')} {enc['height']}x{enc['width']} {d}/{c}"


def check(scan_dir: Path) -> list[str]:
    errors = []

    manifest = None
    manifest_path = scan_dir / "manifest.json"
    if not manifest_path.exists():
        errors.append(f"manifest.json 없음: {manifest_path}")
    else:
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            jsonschema.validate(manifest, MANIFEST_SCHEMA)
        except json.JSONDecodeError as e:
            errors.append(f"manifest.json이 유효한 JSON이 아님: {e}")
        except jsonschema.ValidationError as e:
            errors.append(f"manifest.json 스키마 위반: {e.message}")

    try:
        depth_bytes, conf_bytes, encoding_desc = expected_frame_bytes(manifest)
    except (ValueError, KeyError) as e:
        errors.append(f"manifest.json depth_encoding 해석 실패: {e}")
        depth_bytes, conf_bytes, encoding_desc = expected_frame_bytes(None)

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
                if size != depth_bytes:
                    errors.append(
                        f"{depth_path} 크기가 {size}바이트, 예상 {depth_bytes}바이트({encoding_desc})와 다름"
                    )
                conf_path = depth_path.with_suffix(".conf")
                if not conf_path.exists():
                    errors.append(f"{depth_path}의 짝인 .conf 파일 없음: {conf_path}")
                elif conf_path.stat().st_size != conf_bytes:
                    errors.append(
                        f"{conf_path} 크기가 {conf_path.stat().st_size}바이트, 예상 {conf_bytes}바이트({encoding_desc})와 다름"
                    )

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
