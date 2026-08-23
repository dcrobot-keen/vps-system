"""_select_best_room()의 room 판별/모호성 로직 단위 테스트.

모델/이미지 없이 순수하게 (room_id, num_inliers) 목록만으로 판단하는 함수라
GPU/hloc 없이 빠르게 검증한다. kitchen 사례(서로 다른 room이 같은 inlier로
경합) 재현이 목적.
"""

from __future__ import annotations

from app.localize import MIN_INLIER_MARGIN_RATIO, MIN_INLIERS, _select_best_room


def test_single_room_clears_threshold_succeeds() -> None:
    best_room, best_n, runner_up_room, runner_up_n, reason = _select_best_room(
        [("scan_bedroom", 361)]
    )
    assert reason is None
    assert best_room == "scan_bedroom"
    assert best_n == 361
    assert runner_up_room is None
    assert runner_up_n == 0


def test_clear_margin_over_runner_up_succeeds() -> None:
    best_room, best_n, runner_up_room, runner_up_n, reason = _select_best_room(
        [("scan_kitchen", 200), ("scan_livingroom", 20)]
    )
    assert reason is None
    assert best_room == "scan_kitchen"
    assert runner_up_room == "scan_livingroom"
    assert runner_up_n == 20


def test_below_min_inliers_fails_even_alone() -> None:
    _, best_n, _, _, reason = _select_best_room([("scan_kitchen", MIN_INLIERS - 1)])
    assert reason is not None
    assert best_n == MIN_INLIERS - 1


def test_ambiguous_tie_between_two_rooms_fails() -> None:
    """kitchen 재현: 서로 다른 room이 둘 다 MIN_INLIERS를 넘겨도 격차가 없으면 실패."""
    best_room, best_n, runner_up_room, runner_up_n, reason = _select_best_room(
        [("scan_kitchen", 12), ("scan_livingroom", 12)]
    )
    assert reason is not None
    assert "모호" in reason
    # 디버깅용으로 1등/2등 정보는 채워져 있어야 한다 (채택되진 않지만)
    assert {best_room, runner_up_room} == {"scan_kitchen", "scan_livingroom"}
    assert best_n == 12 and runner_up_n == 12


def test_margin_ratio_boundary() -> None:
    # 정확히 margin_ratio배면 통과 (허용 경계는 fail이 아님)
    runner_up = 20
    boundary_best = int(MIN_INLIER_MARGIN_RATIO * runner_up)
    _, _, _, _, reason_pass = _select_best_room([("a", boundary_best), ("b", runner_up)])
    assert reason_pass is None

    _, _, _, _, reason_fail = _select_best_room([("a", boundary_best - 1), ("b", runner_up)])
    assert reason_fail is not None


def test_no_rooms_attempted_fails() -> None:
    _, _, _, _, reason = _select_best_room([])
    assert reason is not None
