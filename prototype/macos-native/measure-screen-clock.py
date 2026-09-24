#!/usr/bin/env python3
"""Offline relative screen-clock check. Cannot establish absolute A/V sync."""
import json,re,subprocess,sys
from pathlib import Path
folder=Path(sys.argv[1]).resolve()
video=folder/'screen.mp4'
frames=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','frame=best_effort_timestamp_time','-of','json',str(video)]))['frames']
times=[float(f['best_effort_timestamp_time']) for f in frames]
out=folder/'screen-clock-analysis';out.mkdir(exist_ok=True)
rows=[]
for target in [2,15,28]:
    n=next(i for i,t in enumerate(times) if t>=target)
    image=out/f'frame-{n}.png'
    subprocess.run(['ffmpeg','-v','error','-y','-i',str(video),'-vf',f'select=eq(n\\,{n})','-frames:v','1',str(image)],check=True)
    text=subprocess.check_output(['tesseract',str(image),'stdout','--psm','11'],stderr=subprocess.DEVNULL,text=True)
    match=re.search(r'HOST\s+CLOCK\s+(\d+\.\d{3})',text)
    if not match:raise SystemExit(f'Clock OCR unreadable at frame {n}; no result claimed')
    rows.append({'frameIndex':n,'videoPTS':times[n],'displayedHostClock':float(match[1]),'clockText':match[0]})
base=rows[0]
for row in rows:
    row['relativeClockResidualMs']=round(((row['displayedHostClock']-base['displayedHostClock'])-(row['videoPTS']-base['videoPTS']))*1000,3)
report={'samples':rows,'meaning':'Relative progression of drawn host clock versus screen video PTS only; rendering cadence, OCR and rounding affect result. No epoch logged, so absolute screen/audio offset cannot be recovered. Not physical A/V sync or long-term drift proof.'}
(out/'measurement.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
