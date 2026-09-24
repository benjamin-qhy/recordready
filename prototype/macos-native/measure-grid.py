#!/usr/bin/env python3
"""Measure known 60-point reference grid in existing screen frames; no capture."""
import json
from pathlib import Path
import sys
import numpy as np
from PIL import Image
folder=Path(sys.argv[1])
results=[]
def centers(profile):
    threshold=float(np.median(profile)+8)
    indices=np.flatnonzero(profile>threshold)
    groups=np.split(indices,np.where(np.diff(indices)>1)[0]+1)
    return [float(g.mean()) for g in groups if len(g) and len(g)<=5]
for name in ['screen-frame.png','screen-15s.png','screen-28s.png']:
    a=np.asarray(Image.open(folder/name).convert('RGB'),dtype=float)
    # Medians suppress text, cursor and moving marker; exclude border and bottom colors.
    gray=a.mean(axis=2)
    xs=[v+40 for v in centers(np.median(gray[100:610,40:-40],axis=0))]
    ys=[v+100 for v in centers(np.median(gray[100:610,40:-40],axis=1))]
    dx=np.diff(xs);dy=np.diff(ys)
    results.append({'frame':name,'outputPixels':[a.shape[1],a.shape[0]],'gridX':xs,'gridY':ys,
      'medianGridSpacingPixels':[float(np.median(dx)),float(np.median(dy))],
      'expectedGridSpacingPixels':80,'sourceGridSpacingPoints':60,
      'note':'Only known fixed 960x540-point reference to 1280x720 output. Not mixed-DPI or physical sync proof.'})
print(json.dumps(results,indent=2))
