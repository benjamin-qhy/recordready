#!/usr/bin/env python3
"""Exploratory flash/acoustic comparison, not calibrated physical sync certification."""
import json,subprocess,sys
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
p=Path(sys.argv[1]).resolve();video=p/'screen.mp4'
def run(args): return subprocess.check_output(args)
probe=json.loads(run(['ffprobe','-v','error','-show_streams','-of','json',str(video)]))
start=float(next(s['start_time'] for s in probe['streams'] if s['codec_type']=='audio'))
frames=json.loads(run(['ffprobe','-v','error','-select_streams','v:0','-show_entries','frame=best_effort_timestamp_time','-of','json',str(video)]))['frames'];pts=np.array([float(f['best_effort_timestamp_time']) for f in frames])
raw=run(['ffmpeg','-v','error','-i',str(video),'-vf','scale=32:18','-fps_mode','passthrough','-enc_time_base:v','demux','-f','rawvideo','-pix_fmt','gray','-'])
gray=np.frombuffer(raw,np.uint8).reshape(-1,18,32).mean(axis=(1,2))
if len(gray)!=len(pts): raise SystemExit('Frame count mismatch; no measurement emitted')
flashes=np.flatnonzero((gray>160)&np.r_[True,gray[:-1]<=160])
x=np.frombuffer(run(['ffmpeg','-v','error','-i',str(video),'-vn','-ar','48000','-ac','1','-f','f32le','-']),np.float32)
n=960;hop=96;windows=np.lib.stride_tricks.sliding_window_view(x,n)[::hop];power=abs(np.fft.rfft(windows*np.hanning(n),axis=1))**2;freq=np.fft.rfftfreq(n,1/48000);energy=power[:,(freq>=450)&(freq<=600)].sum(axis=1);times=np.arange(len(energy))*hop/48000+start
rows=[];fig,axes=plt.subplots(len(flashes),1,figsize=(9,7),squeeze=False)
for ax,idx in zip(axes[:,0],flashes):
 t=pts[idx];previous=pts[idx-1];baseline=float(np.median(energy[(times>t-.7)&(times<t-.2)]));peak=float(max(energy[(times>t-.2)&(times<t+.4)]));onsets=[]
 for fraction in [.1,.2,.3]:
  above=energy>max(baseline*5,peak*fraction);sustained=np.convolve(above.astype(int),np.ones(6,dtype=int),'valid')==6
  candidates=np.flatnonzero(sustained&(times[:len(sustained)]>t-.15)&(times[:len(sustained)]<t+.2))
  if not len(candidates): raise SystemExit('No sustained tone candidate; manual inspection required')
  onsets.append(float(times[candidates[0]]))
 lo=min(onsets);hi=max(onsets)+n/48000
 rows.append({'firstWhiteFrame':int(idx),'visualBracketSeconds':[float(previous),float(t)],'thresholdWindowStarts':onsets,'audioDetectionEnvelopeSeconds':[lo,hi],'audioMinusVisualEnvelopeMs':[(lo-t)*1000,(hi-previous)*1000]})
 mask=(times>t-.25)&(times<t+.35);ax.plot(times[mask]-t,energy[mask],label='450-600 Hz energy');ax.axvspan(previous-t,0,color='blue',alpha=.15,label='Video transition bracket');ax.axvspan(lo-t,hi-t,color='orange',alpha=.3,label='Audio detection envelope');ax.set_title(f'Event near video PTS {t:.3f}s');ax.set_xlabel('Seconds relative to first white frame');ax.legend(fontsize=8)
fig.tight_layout();fig.savefig(p/'flash-audio-analysis.png',dpi=150)
report={'audioStartPTS':start,'videoFrameCount':len(pts),'events':rows,'limitations':'Detection envelope only, not confidence bound. Uncalibrated rendering/speaker delays, acoustic path, background sounds and window thresholding remain. Not a recorder-only or physical A/V sync verdict.'}
(p/'flash-audio-analysis.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
