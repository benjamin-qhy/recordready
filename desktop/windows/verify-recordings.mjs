import {spawnSync} from 'node:child_process';
import {readFileSync,readdirSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import assert from 'node:assert/strict';
import {validateMP4} from './mp4.mjs';
const ffmpeg=resolve(import.meta.dirname,'node_modules/ffmpeg-static/ffmpeg.exe'),results=[];
for(const report of process.argv.slice(2)){
 const evidence=JSON.parse(readFileSync(report));
 for(const item of evidence.results){
  for(const name of readdirSync(item.directory).filter(name=>/^(screen|camera)\.mp4$/.test(name))){
   const file=join(item.directory,name);await validateMP4(file);
   const probe=spawnSync(ffmpeg,['-hide_banner','-i',file],{encoding:'utf8',windowsHide:true});
   const dimensions=probe.stderr.match(/Video: h264[^\n]*?, (\d+)x(\d+)/);
   assert(dimensions,`H.264 stream missing: ${file}`);
   const expected=name==='screen.mp4'?item.result.outputPixels:item.result.cameraOutputPixels;
   assert.deepEqual(dimensions.slice(1).map(Number),expected);
   const decode=spawnSync(ffmpeg,['-hide_banner','-v','error','-xerror','-i',file,'-map','0','-vf','setpts=N','-af','asetpts=N/SR/TB','-fps_mode','passthrough','-f','null','-'],{encoding:'utf8',windowsHide:true,timeout:120000});
   assert.equal(decode.status,0,`${file}: ${decode.stderr||decode.error}`);assert.equal(decode.stderr.trim(),'');
   const audio=/Audio: aac/.test(probe.stderr);
   if(item.mode)assert.equal(audio,item.mode==='camera-audio');
   const packets=spawnSync(ffmpeg,['-v','error','-i',file,'-map','0:v','-c','copy','-f','framecrc','-'],{encoding:'utf8',windowsHide:true});assert.equal(packets.status,0);const pts=packets.stdout.split('\n').filter(line=>/^0,/.test(line)).map(line=>Number(line.split(',')[2]));assert(pts.length>0);let repeatedPTS=0;for(let i=1;i<pts.length;i++){assert(pts[i]>=pts[i-1],'Video PTS moved backwards');if(pts[i]===pts[i-1])repeatedPTS++;}results.push({file,dimensions:expected,aac:audio,completeDecode:true,frames:pts.length,repeatedPTS});
  }
 }
}
writeFileSync(resolve(import.meta.dirname,'evidence/decode.json'),JSON.stringify({time:new Date().toISOString(),results},null,2));console.log(JSON.stringify(results,null,2));
