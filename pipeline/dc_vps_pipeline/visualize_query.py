"""쿼리 사진 하나를 VPS 서버(server/, POST /localize)에 보내서 위치를 구하고,
scan-to-map-studio가 만든 2D 지도 위에 빨간 점으로 표시한다.

```
python -m dc_vps_pipeline.visualize_query <image> <fx> <fy> <cx> <cy> <width> <height> \
    --scan-to-map-studio-project <scan-to-map-studio 프로젝트 폴더> \
    [--server-url http://localhost:8000/localize] [--output map_with_query.png]
```

`<image>`는 서버가 바로 디코딩할 수 있는 포맷(JPEG/PNG)이어야 한다 — HEIC는 먼저
변환해야 한다(예: macOS `sips -s format jpeg in.HEIC out.jpg`).
`fx/fy/cx/cy/width/height`는 그 이미지의 실제 해상도에 맞는 intrinsics다 — 스캔 때와
해상도가 다르면 비율로 스케일해야 한다(`server/README.md` 참고).

좌표계: VPS 서버가 리턴하는 translation은 ARKit world 좌표계(Y-up)다.
scan-to-map-studio의 지도는 `export_pointcloud.py`/`studio/usdz_import.py`와 동일한
Z-up 변환((x, y, z) -> (x, -z, y))이 이미 적용된 좌표계라, 지도 위 올바른 위치에
찍으려면 같은 변환을 적용해야 한다. 픽셀 변환은 `studio/rasterize.py`가 저장할 때
쓰는 공식(origin/resolution, 상하 반전)을 그대로 재현한다.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import requests
from PIL import Image, ImageDraw


def _parse_map_yaml(yaml_path: Path) -> tuple[tuple[float, float], float]:
    """map_server 스타일 yaml에서 origin(x,y)과 resolution만 뽑는다 (포맷이 단순해서
    PyYAML 없이 직접 파싱 — studio-to-map-studio도 이 포맷을 직접 쓴다)."""
    origin: tuple[float, float] | None = None
    resolution: float | None = None
    for raw_line in yaml_path.read_text().splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if line.startswith("resolution:"):
            resolution = float(line.split(":", 1)[1].strip())
        elif line.startswith("origin:"):
            values = line.split(":", 1)[1].strip().strip("[]").split(",")
            origin = (float(values[0]), float(values[1]))
    if origin is None or resolution is None:
        raise ValueError(f"{yaml_path}에서 origin/resolution을 읽지 못했습니다")
    return origin, resolution


def query_pose(
    server_url: str,
    image_path: Path,
    fx: float,
    fy: float,
    cx: float,
    cy: float,
    width: int,
    height: int,
) -> dict:
    with image_path.open("rb") as f:
        response = requests.post(
            server_url,
            files={"image": (image_path.name, f, "image/jpeg")},
            data={"fx": fx, "fy": fy, "cx": cx, "cy": cy, "width": width, "height": height},
            timeout=120,
        )
    if response.status_code != 200:
        raise RuntimeError(f"VPS 쿼리 실패 (HTTP {response.status_code}): {response.text}")
    return response.json()


def arkit_to_zup(translation: list[float]) -> tuple[float, float, float]:
    """ARKit world(Y-up) -> scan-to-map-studio 관례(Z-up): (x, y, z) -> (x, -z, y).
    export_pointcloud.py의 arkit_to_zup(), studio/usdz_import.py의 _convert_to_zup()과 동일."""
    x, y, z = translation
    return x, -z, y


def draw_marker(
    project_dir: Path,
    translation: list[float],
    output_path: Path,
    radius: int = 6,
) -> Path:
    map_dir = project_dir / "map"
    origin, resolution = _parse_map_yaml(map_dir / "map.yaml")

    zx, zy, _zz = arkit_to_zup(translation)

    image = Image.open(map_dir / "map.png").convert("RGB")
    width, height = image.size

    col = (zx - origin[0]) / resolution
    row_grid = (zy - origin[1]) / resolution
    # rasterize.py의 save_occupancy_preview_png()가 저장 시 np.flipud로 상하를
    # 뒤집는다(image row 0 = max y) -- 여기서도 똑같이 뒤집어야 한다.
    row_image = height - 1 - row_grid

    if not (0 <= col < width and 0 <= row_image < height):
        print(
            f"경고: 위치가 지도 범위 밖입니다 "
            f"(pixel=({col:.1f}, {row_image:.1f}), 지도 크기={image.size})"
        )

    draw = ImageDraw.Draw(image)
    draw.ellipse(
        [col - radius, row_image - radius, col + radius, row_image + radius],
        fill=(255, 0, 0),
        outline=(255, 255, 255),
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(output_path)
    return output_path


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("image", type=Path)
    parser.add_argument("fx", type=float)
    parser.add_argument("fy", type=float)
    parser.add_argument("cx", type=float)
    parser.add_argument("cy", type=float)
    parser.add_argument("width", type=int)
    parser.add_argument("height", type=int)
    parser.add_argument("--server-url", default="http://localhost:8000/localize")
    parser.add_argument("--scan-to-map-studio-project", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()

    result = query_pose(
        args.server_url,
        args.image,
        args.fx,
        args.fy,
        args.cx,
        args.cy,
        args.width,
        args.height,
    )
    print(f"room_id={result.get('room_id')} num_inliers={result.get('num_inliers')}")

    if not result.get("translation"):
        raise SystemExit(f"로컬라이제이션 실패: {result.get('reason', '알 수 없는 이유')}")

    output_path = args.output or (args.scan_to_map_studio_project / "map" / "map_with_query.png")
    draw_marker(args.scan_to_map_studio_project, result["translation"], output_path)
    print(f"저장됨: {output_path}")


if __name__ == "__main__":
    main()
