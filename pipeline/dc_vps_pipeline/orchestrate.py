"""scan_<name>/ 폴더 하나로 hloc VPS DB + (선택) scan-to-map-studio 2D 지도/정합까지
한 번에 처리한다.

```
python -m dc_vps_pipeline.orchestrate <scan_dir> <output_dir> \
    --scan-to-map-studio-dir <scan-to-map-studio 체크아웃 경로> \
    [--robot-map <robot_map_prefix>] [--project-name <name>]
```

- `--scan-to-map-studio-dir`를 생략하면 hloc DB + (아래) 포인트클라우드/usdz까지만 만든다
  (VPS 전용).
- 준다면 https://github.com/dcrobot-keen/scan-to-map-studio 의 `scripts/studio.py new` /
  `process`를 그대로 subprocess로 호출한다 (그 프로젝트는 자체 venv를 쓰므로
  `<scan-to-map-studio-dir>/.venv/bin/python`을 기본으로 쓰고, `--scan-to-map-studio-python`으로
  override 가능). `--robot-map`을 주면 로봇 SLAM 지도와 ICP 정합 + tf export까지 이어진다.

scan_dir에 `scan.usdz`(ios-capture의 ARKit mesh export, `ios-capture/README.md` "scan.usdz
동시 캡처" 참고)가 있으면 그걸 `--usdz`로 우선 쓴다 — depth를 단순 backproject하는
`export_pointcloud.py`의 `--ply`보다 바닥/벽 커버리지가 훨씬 좋다(실측 비교 완료,
2026-08-17: free 셀 1121개 -> 6097개). `scan.usdz`가 없으면(구버전 스캔 등)
`export_pointcloud.py`로 만든 `--ply`로 폴백한다.

scan-to-map-studio는 `--ply` 입력(usdz->ply 변환을 건너뛰는 옵션)을 지원해야 한다 —
2026-08-17에 그 저장소의 `studio/pipeline.py`/`scripts/studio.py`에 추가한 변경.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from . import db_build, export_pointcloud


def _default_studio_python(scan_to_map_studio_dir: Path) -> Path:
    venv_python = scan_to_map_studio_dir / ".venv" / "bin" / "python"
    if venv_python.exists():
        return venv_python
    venv_python_win = scan_to_map_studio_dir / ".venv" / "Scripts" / "python.exe"
    if venv_python_win.exists():
        return venv_python_win
    raise FileNotFoundError(
        f"{scan_to_map_studio_dir}에 .venv를 못 찾았습니다. "
        "scan-to-map-studio의 README대로 venv를 만들거나 --scan-to-map-studio-python으로 지정하세요."
    )


def orchestrate(
    scan_dir: Path,
    output_dir: Path,
    scan_to_map_studio_dir: Path | None = None,
    scan_to_map_studio_python: Path | None = None,
    robot_map_prefix: Path | None = None,
    project_name: str | None = None,
    classify: bool = True,
) -> None:
    # subprocess.run(cwd=scan_to_map_studio_dir) 아래에서 상대경로가 두 번 적용되지
    # 않도록 여기서 전부 절대경로로 고정한다 (예: ../../scan-to-map-studio 를 넘기면
    # studio.py 경로가 D:\code\scan-to-map-studio 로 어긋나던 문제).
    scan_dir = scan_dir.resolve()
    output_dir = output_dir.resolve()
    if scan_to_map_studio_dir is not None:
        scan_to_map_studio_dir = scan_to_map_studio_dir.resolve()
    if scan_to_map_studio_python is not None:
        scan_to_map_studio_python = scan_to_map_studio_python.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    project_name = project_name or scan_dir.name

    print(f"[1/3] hloc VPS DB 빌드 -> {output_dir}")
    db_build.build_db(scan_dir, output_dir)

    usdz_path = scan_dir / "scan.usdz"
    use_usdz = usdz_path.exists()
    if use_usdz:
        print(f"[2/3] scan.usdz 발견 -> 이걸 씀 ({usdz_path})")
        pointcloud_path = None
    else:
        pointcloud_path = output_dir / "base_map.ply"
        print(f"[2/3] scan.usdz 없음 -> depth 기반 포인트클라우드 export -> {pointcloud_path}")
        export_pointcloud.export_pointcloud(scan_dir, pointcloud_path)

    if scan_to_map_studio_dir is None:
        print("[3/3] --scan-to-map-studio-dir 없음 -- 2D 지도/정합 스킵 (VPS DB만 생성됨)")
        return

    studio_python = scan_to_map_studio_python or _default_studio_python(scan_to_map_studio_dir)
    studio_script = scan_to_map_studio_dir / "scripts" / "studio.py"
    if not studio_script.exists():
        raise FileNotFoundError(f"scan-to-map-studio를 못 찾았습니다: {studio_script}")

    print(f"[3/3] scan-to-map-studio 실행 -> project '{project_name}'")
    subprocess.run(
        [str(studio_python), str(studio_script), "new", project_name],
        cwd=scan_to_map_studio_dir,
        check=True,
    )

    process_cmd = [str(studio_python), str(studio_script), "process", project_name]
    if use_usdz:
        process_cmd += ["--usdz", str(usdz_path.resolve())]
    else:
        process_cmd += ["--ply", str(pointcloud_path.resolve())]
    if robot_map_prefix is not None:
        process_cmd += ["--robot-map", str(robot_map_prefix.resolve())]
    if classify:
        # 벽/가구 분류가 있어야 output.geojson에 wall/furniture 피처가 들어가고,
        # pathfinder의 import-scan-to-map-studio.mjs 가 방 외곽선만 받는 일이 없다.
        process_cmd += ["--classify"]
    subprocess.run(process_cmd, cwd=scan_to_map_studio_dir, check=True)

    project_dir = scan_to_map_studio_dir / "projects" / project_name
    print(f"done. hloc DB: {output_dir}")
    print(f"done. scan-to-map-studio project: {project_dir} (report.html 참고)")
    if robot_map_prefix is not None:
        print(
            f"registration_transform이 나왔다면 {project_dir}/align.html에서 확인 후 "
            f"scripts/export_tf.py로 ROS tf를 뽑아서 ros2_ws/src/dc_vps_bridge의 "
            "scan_basemap 프레임으로 publish하세요."
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scan_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--scan-to-map-studio-dir", type=Path, default=None)
    parser.add_argument("--scan-to-map-studio-python", type=Path, default=None)
    parser.add_argument("--robot-map", type=Path, default=None, dest="robot_map_prefix")
    parser.add_argument("--project-name", type=str, default=None)
    parser.add_argument(
        "--no-classify",
        action="store_true",
        help="studio.py process 를 --classify 없이 실행 (기본은 켬: output.geojson 에 벽/가구가 필요함)",
    )
    args = parser.parse_args()

    try:
        orchestrate(
            args.scan_dir,
            args.output_dir,
            scan_to_map_studio_dir=args.scan_to_map_studio_dir,
            scan_to_map_studio_python=args.scan_to_map_studio_python,
            robot_map_prefix=args.robot_map_prefix,
            project_name=args.project_name,
            classify=not args.no_classify,
        )
    except subprocess.CalledProcessError as error:
        print(f"scan-to-map-studio 실행 실패 (exit {error.returncode})", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
