import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';import {resolve,join} from 'node:path';import assert from 'node:assert/strict';
const data=resolve(process.argv[2]||'desktop/windows/.validation/development'),control=JSON.parse(readFileSync(join(data,'test-control.json')));
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function call(action,args={},reject=false){const response=await fetch(`http://127.0.0.1:${control.port}`,{method:'POST',headers:{authorization:`Bearer ${control.secret}`,'content-type':'application/json'},body:JSON.stringify({action,...args})});const value=await response.json();if(reject){assert(!response.ok);return value;}if(!response.ok)throw Error(JSON.stringify(value));return value;}
async function wait(phase,timeout=30000){const until=Date.now()+timeout;while(Date.now()<until){const s=await call('status');if(s.phase===phase)return s;if(s.phase==='failed')throw Error(JSON.stringify(s));await sleep(300);}throw Error(`Timed out waiting for ${phase}`);}
const results=[];
for(const mode of ['camera-audio','silent']){
 await call('configure',{width:mode==='silent'?720:1280,height:mode==='silent'?1280:720,quality:720,camera:mode!=='silent',microphone:mode!=='silent'});
 await call('start');assert.equal((await call('status')).phase,'countdown');
 if(mode==='silent'){await call('cancel');assert.equal((await call('status')).phase,'ready');await call('start');}
 await wait('recording');const busy=await call('configure',{width:640},true);assert.equal(busy.error,'session_busy');
 await call('show-prompt');await call('prompt',{text:'RecordReady Windows 实机验收\n录制、暂停、继续、停止。',playing:true});await sleep(3500);
 await call('pause');const paused=await call('status');await sleep(2000);assert.equal((await call('status')).elapsed,paused.elapsed);
 await call('resume');await call('hide-prompt');await sleep(2500);const saved=await call('stop');assert.equal(saved.phase,'saved');assert.equal(saved.result.saveResults.screen,'saved');assert.equal(saved.result.saveResults.camera,mode==='silent'?'not-requested':'saved');results.push({mode,directory:saved.directory,result:saved.result,elapsed:saved.elapsed});
}
await call('prompt',{text:'',reset:true});await call('configure',{camera:false,microphone:false});mkdirSync('desktop/windows/evidence',{recursive:true});writeFileSync('desktop/windows/evidence/recording.json',JSON.stringify({time:new Date().toISOString(),results},null,2));console.log(JSON.stringify(results,null,2));
