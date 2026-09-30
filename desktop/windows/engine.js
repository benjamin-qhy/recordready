const bridge=window.recordready, camera=document.querySelector('#camera'),screenVideo=document.querySelector('#screen');
let canvas=document.querySelector('#output');
let config={},devices=[],cameraStream,micStream,screenStream,canvasStream,audioContext,analyser,recorders=[],timer,levelTimer,token,writeFailure,stopping=false;
const tracks=stream=>stream?.getTracks().forEach(t=>t.stop());
const report=value=>bridge.report(value);
async function catalog(){devices=await navigator.mediaDevices.enumerateDevices();return {cameras:devices.filter(d=>d.kind==='videoinput').map(d=>({id:d.deviceId,name:d.label||'Camera'})),microphones:devices.filter(d=>d.kind==='audioinput'&&d.deviceId!=='default'&&d.deviceId!=='communications').map(d=>({id:d.deviceId,name:d.label||'Microphone'}))};}
function watch(stream){for(const track of stream.getTracks())track.addEventListener('ended',()=>{if(!stopping)report({error:'device_disconnected',fatal:recorders.length>0})});}
async function monitor(next){
 config=next;
 if(recorders.length)throw Error('session_busy');
 stopping=true;tracks(cameraStream);tracks(micStream);cameraStream=micStream=undefined;clearInterval(levelTimer);if(audioContext)await audioContext.close();audioContext=undefined;
 stopping=false;
 try{
  if(config.camera){cameraStream=await navigator.mediaDevices.getUserMedia({video:{deviceId:config.cameraID?{exact:config.cameraID}:undefined,width:{ideal:1920},height:{ideal:1080},frameRate:{ideal:30}},audio:false});camera.srcObject=cameraStream;await camera.play();watch(cameraStream);}
  if(config.microphone){micStream=await navigator.mediaDevices.getUserMedia({audio:{deviceId:config.microphoneID?{exact:config.microphoneID}:undefined,echoCancellation:false,noiseSuppression:false,autoGainControl:false},video:false});watch(micStream);audioContext=new AudioContext();analyser=audioContext.createAnalyser();audioContext.createMediaStreamSource(micStream).connect(analyser);const samples=new Float32Array(analyser.fftSize);levelTimer=setInterval(()=>{analyser.getFloatTimeDomainData(samples);report({level:Math.min(1,Math.sqrt(samples.reduce((s,n)=>s+n*n,0)/samples.length)*5)})},120);}
  camera.style.transform=config.mirror?'scaleX(-1)':'';camera.style.borderRadius=config.previewShape==='circle'?'50%':'0';
  return {catalog:await catalog(),cameraReady:!!cameraStream,microphoneReady:!!micStream,cameraResolution:cameraStream?`${camera.videoWidth}×${camera.videoHeight}`:undefined};
 }catch(e){stopping=true;tracks(cameraStream);tracks(micStream);cameraStream=micStream=undefined;stopping=false;throw e;}
}
function paint(){
 const ctx=canvas.getContext('2d',{alpha:false,willReadFrequently:canvas.height>2160}),r=config.region,b=config.displayBounds;
 const sx=screenVideo.videoWidth/b.width,sy=screenVideo.videoHeight/b.height;
 ctx.drawImage(screenVideo,(r.x-b.x)*sx,(r.y-b.y)*sy,r.width*sx,r.height*sy,0,0,canvas.width,canvas.height);
 if(config.camera&&camera.videoWidth){const p=config.cameraBounds;const x=(p.x-r.x)/r.width*canvas.width,y=(p.y-r.y)/r.height*canvas.height,w=p.width/r.width*canvas.width,h=p.height/r.height*canvas.height;
  ctx.save();ctx.beginPath();if(config.previewShape==='circle')ctx.ellipse(x+w/2,y+h/2,w/2,h/2,0,0,Math.PI*2);else ctx.rect(x,y,w,h);ctx.clip();if(config.mirror){ctx.translate(x+w,y);ctx.scale(-1,1);}else ctx.translate(x,y);
  const ratio=Math.max(w/camera.videoWidth,h/camera.videoHeight),cw=w/ratio,ch=h/ratio;ctx.drawImage(camera,(camera.videoWidth-cw)/2,(camera.videoHeight-ch)/2,cw,ch,0,0,w,h);ctx.restore();
 }
}
async function start(next){
 config=next;token=config.token;writeFailure=null;
 if(config.camera&&!cameraStream||config.microphone&&!micStream)throw Error('device_not_ready');
 try{
  screenStream=await navigator.mediaDevices.getUserMedia({audio:false,video:{mandatory:{chromeMediaSource:'desktop',chromeMediaSourceId:config.sourceID,minFrameRate:30,maxFrameRate:30}}});watch(screenStream);screenVideo.srcObject=screenStream;await screenVideo.play();
  // Recreate the context per session: portrait 4K needs CPU canvas readback on the acceptance GPU.
  const previous=canvas;canvas=document.createElement('canvas');canvas.id='output';previous.replaceWith(canvas);
  [canvas.width,canvas.height]=config.outputPixels;paint();timer=setInterval(paint,1000/30);canvasStream=canvas.captureStream(30);
  const create=(name,videoTracks)=>{
   const media=new MediaStream([...videoTracks,...(micStream?.getAudioTracks()??[])]),mimeType=config.microphone?'video/mp4;codecs=avc1.420033,mp4a.40.2':'video/mp4;codecs=avc1.420033';
   if(!MediaRecorder.isTypeSupported(mimeType))throw Error('mp4_encoder_unavailable');
   const recorder=new MediaRecorder(media,{mimeType,videoBitsPerSecond:Math.min(24000000,Math.max(4000000,canvas.width*canvas.height*4)),audioBitsPerSecond:128000});
   let signal;const ready=new Promise(resolve=>signal=resolve);const entry={name,recorder,pending:Promise.resolve(),bytes:0,queued:0,ready};
   recorder.ondataavailable=e=>{if(!e.data.size)return;signal();entry.queued+=e.data.size;if(entry.queued>64*1024*1024){writeFailure=Error('disk_too_slow');report({error:writeFailure.message,fatal:true});}
    entry.pending=entry.pending.then(async()=>{await bridge.chunk(token,name,await e.data.arrayBuffer());entry.bytes+=e.data.size;entry.queued-=e.data.size;}).catch(e=>{writeFailure=e;report({error:String(e),fatal:true})});};
   recorder.onerror=e=>{writeFailure=Error(e.error?.message||'encoder_failed');report({error:writeFailure.message,fatal:true})};
   recorders.push(entry);recorder.start(500);
  };
  create('screen',canvasStream.getVideoTracks());if(config.camera)create('camera',cameraStream.getVideoTracks());
  let warmup;try{await Promise.race([Promise.all(recorders.map(r=>r.ready)),new Promise((_,reject)=>warmup=setTimeout(()=>reject(Error('mp4_encoder_no_output')),15000))]);}finally{clearTimeout(warmup);}
  return {cameraPixels:cameraStream?[camera.videoWidth,camera.videoHeight]:undefined};
 }catch(e){await stop().catch(()=>{});throw e;}
}
async function stop(){
 stopping=true;clearInterval(timer);
 const results=await Promise.all(recorders.map(async entry=>{if(entry.recorder.state!=='inactive')await new Promise(resolve=>{entry.recorder.addEventListener('stop',resolve,{once:true});entry.recorder.stop()});await entry.pending;return {name:entry.name,bytes:entry.bytes};}));
 recorders=[];tracks(screenStream);tracks(canvasStream);screenStream=canvasStream=undefined;stopping=false;
 return {results,error:writeFailure?String(writeFailure):''};
}
bridge.on('engine',async({id,action,value})=>{try{let result;
 if(action==='catalog')result=await catalog();else if(action==='monitor')result=await monitor(value);else if(action==='start')result=await start(value);else if(action==='stop')result=await stop();else if(action==='pause'||action==='resume'){for(const r of recorders)r.recorder[action]();result={};}else if(action==='config'){config={...config,...value};camera.style.transform=config.mirror?'scaleX(-1)':'';camera.style.borderRadius=config.previewShape==='circle'?'50%':'0';result={};}else throw Error('unknown_engine_action');
 bridge.engineReply(id,result);
 }catch(e){bridge.engineReply(id,null,e.message||String(e))}});
navigator.mediaDevices.addEventListener('devicechange',async()=>report({catalog:await catalog()}));
report({engineReady:true});
