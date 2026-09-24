#!/usr/bin/env python3
"""Measure known 60-point reference grid in existing screen frames; no capture."""
import json
from pathlib import Path
import sys
import numpy as np
from PIL import Image
folder=Path(sys.argv[1])
results=[]
meta=json.loads((folder / "session.json").read_text())
source_width,source_height=meta["sourceRectPoints"][2:]
def centers(profile):
    threshold=float(np.median(profile)+8)
    indices=np.flatnonzero(profile>threshold)
    groups=np.split(indices,np.where(np.diff(indices)>1)[0]+1)
    return [float(g.mean()) for g in groups if len(g) and len(g)<=8]
for name in ['screen-frame.png','screen-15s.png','screen-28s.png']:
    a=np.asarray(Image.open(folder/name).convert('RGB'),dtype=float)
    # Median columns and 10th-percentile rows suppress text and markers; exclude border and bottom colors.
    gray=a.mean(axis=2)
    height,width=gray.shape
    margin=max(20,round(width*0.025))
    top,bottom=round(height*0.15),round(height*0.80)
    xs=[v+margin for v in centers(np.median(gray[round(height*0.20):round(height*0.42),margin:-margin],axis=0))]
    ys=[v+top for v in centers(np.quantile(gray[top:bottom,margin:-margin],0.10,axis=1))]
    dx=np.diff(xs);dy=np.diff(ys)
    results.append({'frame':name,'outputPixels':[a.shape[1],a.shape[0]],'gridX':xs,'gridY':ys,
      'medianGridSpacingPixels':[float(np.median(dx)),float(np.median(dy))],
      'expectedGridSpacingPixels':[60*width/source_width,60*height/source_height],'sourceGridSpacingPoints':60,
      'note':'Known 60-point reference grid only; expected spacing uses session source rectangle. Not mixed-DPI or physical sync proof.'})
print(json.dumps(results,indent=2))
