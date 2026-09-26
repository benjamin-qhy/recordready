#!/usr/bin/env python3
"""Validate decoded presentation timestamps, not encoder target metadata."""
import json
import subprocess
import sys

result = subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
     "frame=best_effort_timestamp_time", "-of", "json", sys.argv[1]],
    check=True, capture_output=True, text=True,
)
times = [float(frame["best_effort_timestamp_time"])
         for frame in json.loads(result.stdout)["frames"]]
bad = [b - a for a, b in zip(times, times[1:]) if abs(b - a - 1 / 30) > 0.0001]
passed = len(times) > 1 and not bad
print(json.dumps({"passed": passed, "frames": len(times), "bad_intervals": len(bad),
                  "first_pts": times[0] if times else None}))
sys.exit(0 if passed else 1)
