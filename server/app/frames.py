"""방(room) 좌표계 -> 그룹 기준 좌표계.

/localize 는 매칭된 room(=scan_<name> DB)의 ARKit world 좌표로 pose 를 돌려준다. 방이 여러 개인
현장에서는 pathfinder 프로젝트/시뮬레이터 월드가 "그룹 기준 스캔" 좌표계(정합 워크스페이스가
만든 merged 슬라이스맵)를 쓰므로, 소비자가 방별 ScanAlignment 를 알아야 한다. 이 모듈은
scan-group-alignment-v1 문서(group_alignment.json, scan-format/SCAN_FORMAT.md)를 읽어 room_id
(= scan id) 마다 frame 을 만들어 준다 -- 응답에 실려 나가면 ros-chromium 의 VpsCorrectionNode
(applyFrame) 가 그대로 적용한다. 수학은 클라이언트가 하고 서버는 변환값만 전달한다.

환경변수 DC_VPS_GROUP_ALIGNMENT=<group_alignment.json 경로>. 없으면 frame 은 None(=단일 방,
변환 없음). 기준 스캔은 항등 변환으로 나간다.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

ALIGNMENT_FORMAT = "scan-group-alignment-v1"
IDENTITY = {"offsetX": 0.0, "offsetZ": 0.0, "yawRadians": 0.0, "method": "reference"}


class GroupFrames:
    def __init__(self, doc: dict | None):
        self.group: str | None = None
        self.reference: str | None = None
        self.alignments: dict[str, dict] = {}
        if doc is None:
            return
        if doc.get("format") != ALIGNMENT_FORMAT:
            raise ValueError(f"group alignment: format {doc.get('format')!r} != {ALIGNMENT_FORMAT}")
        if not isinstance(doc.get("reference"), str) or not doc["reference"]:
            raise ValueError("group alignment: reference missing")
        self.group = doc.get("group")
        self.reference = doc["reference"]
        for scan, a in (doc.get("alignments") or {}).items():
            vals = {}
            for k in ("offsetX", "offsetZ", "yawRadians"):
                v = a.get(k)
                if not isinstance(v, (int, float)):
                    raise ValueError(f"group alignment: alignments.{scan}.{k} is not a number")
                vals[k] = float(v)
            vals["method"] = str(a.get("method", "unknown"))
            self.alignments[scan] = vals

    @property
    def enabled(self) -> bool:
        return self.reference is not None

    def frame_for(self, room_id: str | None) -> dict | None:
        """{group, mapId, reference, alignment} for a room, None when unknown/disabled."""
        if not self.enabled or room_id is None:
            return None
        if room_id == self.reference:
            alignment = dict(IDENTITY)
        elif room_id in self.alignments:
            alignment = dict(self.alignments[room_id])
        else:
            return None
        return {"group": self.group, "mapId": self.group, "reference": self.reference, "alignment": alignment}

    def describe(self) -> dict:
        return {"enabled": self.enabled, "group": self.group, "reference": self.reference, "rooms": sorted(self.alignments)}


def load_group_frames(path: str | os.PathLike | None) -> GroupFrames:
    if not path:
        return GroupFrames(None)
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"DC_VPS_GROUP_ALIGNMENT: {p} not found")
    return GroupFrames(json.loads(p.read_text(encoding="utf-8")))


def frames_from_env() -> GroupFrames:
    return load_group_frames(os.environ.get("DC_VPS_GROUP_ALIGNMENT"))
