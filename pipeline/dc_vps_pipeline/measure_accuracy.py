"""쿼리 사진의 VPS 추정 위치와 실제 위치를 비교해서 정확도 오차를 미터 단위로
측정한다.

지도 이미지(scan-to-map-studio의 map.png) 위에 VPS 추정 위치를 빨간 점으로
띄우고, 사용자가 "실제로 여기 서 있었다"는 지점을 클릭하면 그 픽셀 거리를
map.yaml의 resolution(m/pixel)으로 환산해서 오차(m)를 계산한다. 자 들고 실측할
필요 없이, 지도가 이미 실제 스캔에서 나온 정확한 축척이라는 걸 이용한다.

```
python -m dc_vps_pipeline.measure_accuracy <image> <fx> <fy> <cx> <cy> <width> <height> \
    --scan-to-map-studio-project <scan-to-map-studio 프로젝트 폴더>
```

클릭 대신 픽셀 좌표를 이미 알고 있으면(예: 스크립트로 자동화) `--ground-truth-pixel
col,row`로 바로 넘길 수 있다 — 이 경우 창을 띄우지 않고 바로 계산한다.

좌표 변환/서버 호출은 `visualize_query.py`와 동일한 로직을 그대로 재사용한다.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image

from .visualize_query import _parse_map_yaml, arkit_to_zup, query_pose


def estimated_pixel(project_dir: Path, translation: list[float]) -> tuple[float, float, float]:
    """VPS 추정 translation -> 지도 픽셀 좌표(col, row) + resolution(m/pixel).
    `visualize_query.draw_marker()`와 같은 변환(Z-up 변환 + 상하 반전)이다."""
    map_dir = project_dir / "map"
    origin, resolution = _parse_map_yaml(map_dir / "map.yaml")
    zx, zy, _zz = arkit_to_zup(translation)

    image = Image.open(map_dir / "map.png")
    height = image.size[1]

    col = (zx - origin[0]) / resolution
    row_grid = (zy - origin[1]) / resolution
    row_image = height - 1 - row_grid
    return col, row_image, resolution


def report_error(est_col: float, est_row: float, gt_col: float, gt_row: float, resolution: float) -> float:
    pixel_distance = math.hypot(gt_col - est_col, gt_row - est_row)
    meters = pixel_distance * resolution
    print(
        f"오차: {meters:.3f} m  (픽셀 거리 {pixel_distance:.1f}px x "
        f"resolution {resolution:.4f} m/px)"
    )
    return meters


def save_annotated(
    project_dir: Path,
    est_col: float,
    est_row: float,
    gt_col: float,
    gt_row: float,
    output_path: Path,
) -> Path:
    from PIL import ImageDraw

    map_image = Image.open(project_dir / "map" / "map.png").convert("RGB")
    draw = ImageDraw.Draw(map_image)
    radius = 6
    # VPS 추정 위치 -- 빨강 (visualize_query.py draw_marker()와 같은 색 관례)
    draw.ellipse(
        [est_col - radius, est_row - radius, est_col + radius, est_row + radius],
        fill=(255, 0, 0), outline=(255, 255, 255),
    )
    # 실제 위치 -- 초록
    draw.ellipse(
        [gt_col - radius, gt_row - radius, gt_col + radius, gt_row + radius],
        fill=(0, 200, 0), outline=(255, 255, 255),
    )
    draw.line([est_col, est_row, gt_col, gt_row], fill=(255, 255, 0), width=2)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    map_image.save(output_path)
    return output_path


def pick_ground_truth_interactively(project_dir: Path, image_name: str, est_col: float, est_row: float) -> tuple[float, float]:
    """지도를 띄워서 사용자가 실제 위치를 클릭하게 한다. 클릭한 (col, row)를 반환."""
    import matplotlib.pyplot as plt

    map_image = Image.open(project_dir / "map" / "map.png").convert("RGB")

    fig, ax = plt.subplots(figsize=(10, 10))
    ax.imshow(map_image)
    ax.scatter([est_col], [est_row], c="red", s=90, marker="o", label="VPS 추정 위치", zorder=3)
    ax.set_title(f"'{image_name}'을 실제로 찍은 위치를 지도에서 클릭하세요")
    ax.legend(loc="upper right")

    picked: list[tuple[float, float]] = []

    def on_click(event):
        if event.xdata is None or event.ydata is None or event.inaxes != ax:
            return
        picked.append((event.xdata, event.ydata))
        plt.close(fig)

    fig.canvas.mpl_connect("button_press_event", on_click)
    plt.show()

    if not picked:
        raise SystemExit("클릭 없이 창이 닫혔습니다 -- 실제 위치를 클릭해야 오차를 계산할 수 있습니다.")
    return picked[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", type=Path)
    parser.add_argument("fx", type=float)
    parser.add_argument("fy", type=float)
    parser.add_argument("cx", type=float)
    parser.add_argument("cy", type=float)
    parser.add_argument("width", type=int)
    parser.add_argument("height", type=int)
    parser.add_argument("--server-url", default="http://localhost:8000/localize")
    parser.add_argument("--scan-to-map-studio-project", type=Path, required=True)
    parser.add_argument(
        "--ground-truth-pixel", type=str, default=None,
        help="실제 위치를 이미 아는 경우 'col,row' 형식으로 직접 지정 (생략하면 지도를 띄워 클릭으로 입력)",
    )
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()

    result = query_pose(
        args.server_url, args.image, args.fx, args.fy, args.cx, args.cy, args.width, args.height
    )
    print(f"room_id={result.get('room_id')} num_inliers={result.get('num_inliers')}")
    if not result.get("translation"):
        raise SystemExit(f"로컬라이제이션 실패: {result.get('reason', '알 수 없는 이유')}")

    est_col, est_row, resolution = estimated_pixel(
        args.scan_to_map_studio_project, result["translation"]
    )
    print(f"VPS 추정 위치(지도 픽셀): ({est_col:.1f}, {est_row:.1f})")

    if args.ground_truth_pixel:
        gt_col, gt_row = (float(v) for v in args.ground_truth_pixel.split(","))
    else:
        gt_col, gt_row = pick_ground_truth_interactively(
            args.scan_to_map_studio_project, args.image.name, est_col, est_row
        )
        print(f"실제 위치(지도 픽셀, 클릭): ({gt_col:.1f}, {gt_row:.1f})")

    report_error(est_col, est_row, gt_col, gt_row, resolution)

    output_path = args.output or (
        args.scan_to_map_studio_project / "map" / "accuracy_check.png"
    )
    save_annotated(args.scan_to_map_studio_project, est_col, est_row, gt_col, gt_row, output_path)
    print(f"저장됨: {output_path} (빨강=VPS 추정, 초록=실제)")


if __name__ == "__main__":
    main()
