#!/usr/bin/env python3
"""Inspect native-probe outputs. This does NOT prove physical audio/video sync."""
import json
import pathlib
import subprocess
import sys

folder = pathlib.Path(sys.argv[1]).resolve()
report = {"session": str(folder), "files": {}, "physical_sync": "UNMEASURED: requires visible/audible reference events"}
for name in ("screen", "camera"):
    path = folder / f"{name}.mp4"
    if not path.exists():
        report["files"][name] = {"error": "file missing"}
        continue
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)], capture_output=True, text=True)
    if probe.returncode:
        report["files"][name] = {"error": probe.stderr}
        continue
    data = json.loads(probe.stdout)
    decode = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-fps_mode", "passthrough", "-enc_time_base:v", "demux", "-f", "null", "-"], capture_output=True, text=True)
    frames = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", str(path)], capture_output=True, text=True, check=True)
    times = [float(f["best_effort_timestamp_time"]) for f in json.loads(frames.stdout)["frames"] if "best_effort_timestamp_time" in f]
    report["files"][name] = {
        "bytes": path.stat().st_size,
        "format": data["format"].get("format_name"),
        "duration": data["format"].get("duration"),
        "decode_exit": decode.returncode,
        "decode_errors": decode.stderr,
        "non_increasing_video_pts": sum(b <= a for a, b in zip(times, times[1:])),
        "max_video_gap_seconds": max((b-a for a, b in zip(times, times[1:])), default=None),
        "streams": [{key: stream.get(key) for key in ("codec_type", "codec_name", "width", "height", "avg_frame_rate", "sample_rate", "channels", "start_time", "duration", "nb_frames")} for stream in data["streams"]],
    }
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "2", "-i", str(path), "-frames:v", "1", str(folder / f"{name}-frame.png")], check=True)
memory = folder / "memory.json"
if memory.exists():
    rows = json.loads(memory.read_text())
    values = [r["residentMB"] for r in rows if r["residentMB"] >= 0]
    if values:
        report["memory"] = {"samples": len(values), "firstMB": values[0], "lastMB": values[-1], "peakMB": max(values), "note": "Short runs do not establish bounded long-record memory."}
(folder / "analysis.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
print(json.dumps(report, indent=2, ensure_ascii=False))
