"""app/frames.py -- room -> group frame lookup from a scan-group-alignment-v1 file."""
import json
import math

import pytest

from app.frames import GroupFrames, load_group_frames


DOC = {
    "format": "scan-group-alignment-v1",
    "group": "project_x",
    "reference": "scan_A",
    "alignments": {"scan_B": {"offsetX": 1.5, "offsetZ": -0.5, "yawRadians": math.radians(30), "method": "icp"}},
}


def test_disabled_without_file():
    f = load_group_frames(None)
    assert not f.enabled
    assert f.frame_for("scan_A") is None
    assert f.describe()["enabled"] is False


def test_reference_is_identity_and_rooms_get_their_alignment():
    f = GroupFrames(DOC)
    ref = f.frame_for("scan_A")
    assert ref["alignment"] == {"offsetX": 0.0, "offsetZ": 0.0, "yawRadians": 0.0, "method": "reference"}
    assert ref["mapId"] == "project_x" and ref["reference"] == "scan_A"
    b = f.frame_for("scan_B")
    assert b["alignment"]["offsetX"] == 1.5 and b["alignment"]["method"] == "icp"
    assert f.frame_for("scan_Z") is None
    assert f.frame_for(None) is None


def test_validation():
    with pytest.raises(ValueError):
        GroupFrames({"format": "nope", "reference": "a"})
    with pytest.raises(ValueError):
        GroupFrames({"format": "scan-group-alignment-v1", "reference": "a", "alignments": {"b": {"offsetX": "x"}}})


def test_load_from_file(tmp_path):
    p = tmp_path / "group_alignment.json"
    p.write_text(json.dumps(DOC), encoding="utf-8")
    f = load_group_frames(p)
    assert f.enabled and f.describe()["rooms"] == ["scan_B"]
    with pytest.raises(FileNotFoundError):
        load_group_frames(tmp_path / "missing.json")
