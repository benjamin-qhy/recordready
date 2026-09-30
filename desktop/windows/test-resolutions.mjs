import {readFileSync,writeFileSync} from 'node:fs';import {join,resolve} from 'node:path';import assert from 'node:assert/strict';
const root=resolve(process.argv[2]||resolve(import.meta.dirname,'.validation/installed-data')),control=JSON.parse(readFileSync(join(root,'test-control.json'))),sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function call(action,args={},expectedError=false){const response=await fetch(`http://127.0.0.1:${control.port}`,{method:'POST',headers:{authorization:`Bearer ${control.secret}`,'content-type':'application/json'},body:JSON.stringify({action,...args})});const value=await response.json();if(expectedError){assert(!response.ok);return value;}if(!response.ok)throw Error(JSON.stringify(value));return value;}
async function wait(phase){const deadline=Date.now()+30000;while(Date.now()<deadline){const s=await call('status');if(s.phase===phase)return s;if(s.phase==='failed'&&phase!=='failed')throw Error(JSON.stringify(s));await sleep(200);}throw Error('capture_timeout');}
const results=[],before=await call('status');
for(const [width,height,quality] of [[1080,1920,2160],[1080,1920,1080],[1920,1080,2160]]){
 await call('configure',{camera:false,microphone:false,width,height,quality});await call('start');await wait('recording');const quit=await call('quit',{},true);assert.equal(quit.error,'session_busy');await sleep(10000);const saved=await call('stop');assert.equal(saved.phase,'saved',JSON.stringify(saved));results.push({width,height,quality,directory:saved.directory,result:saved.result});
}
const invalid=await call('configure',{displayID:'missing-monitor'},true);assert.equal(invalid.error,'missing_display');
await call('configure',{directory:resolve(import.meta.dirname,'package.json')});await call('start');const failed=await wait('failed');assert(failed.error);assert(!failed.result.saveResults?.screen);
await call('configure',{directory:resolve(import.meta.dirname,'.validation/installed-recordings'),width:1280,height:720,quality:720});
writeFileSync(resolve(import.meta.dirname,'evidence/resolutions.json'),JSON.stringify({version:before.applicationVersion||'development',time:new Date().toISOString(),results,invalidDirectoryRejected:failed.error,quitDuringRecordingRejected:true,missingDisplayRejected:true},null,2));console.log(JSON.stringify(results));
