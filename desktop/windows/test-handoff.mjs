import {spawn} from 'node:child_process';
import {readFileSync,writeFileSync,copyFileSync,mkdirSync,existsSync,readdirSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
import {verifyRelease} from './update-manifest.mjs';
import {verifyInstaller} from './installer-integrity.mjs';

const here=resolve(import.meta.dirname),version=process.argv[2];
if(!/^\d+\.\d+\.\d+-windows\.\d+$/.test(version||''))throw Error('Pass the signed candidate version to install into the isolated acceptance copy');
const data=join(here,'.validation/installed-data'),executable=join(here,'.validation/installed/RecordReady.exe');
const control=JSON.parse(readFileSync(join(data,'test-control.json'))),config=JSON.parse(readFileSync(join(here,'resources/update-config.json')));
const folder=join(here,'release/published',version),release=verifyRelease(readFileSync(join(folder,'release.json'),'utf8'),config.publicKey);
const original=join(folder,release.file.name);await verifyInstaller(original,release.file);
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const hash=file=>createHash('sha256').update(readFileSync(file)).digest('hex');
function inventory(root){const found={};if(!existsSync(root))return found;for(const item of readdirSync(root,{withFileTypes:true})){const path=join(root,item.name);if(item.isDirectory())Object.assign(found,inventory(path));else if(item.name.endsWith('.mp4'))found[path]=hash(path);}return found;}
const before={settings:hash(join(data,'settings.json')),recordings:inventory(join(here,'.validation/installed-recordings'))};
const stage=join(here,'.validation/helper',randomUUID());mkdirSync(stage,{recursive:true});
const runner=join(stage,'update-runner.exe'),installer=join(stage,'setup.exe');copyFileSync(join(here,'resources/update-runner.exe'),runner);copyFileSync(original,installer);await verifyInstaller(installer,release.file);
const child=spawn(runner,[String(control.pid),installer,executable],{windowsHide:true,stdio:'ignore',env:{...process.env,RECORDREADY_TEST_DATA:data,RECORDREADY_TEST_CONTROL:'1'}});
const ended=new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>resolve(code));});
for(let i=0;!existsSync(installer+'.ready');i++){if(i===100)throw Error('helper_ack_timeout');await sleep(50);}
const response=await fetch(`http://127.0.0.1:${control.port}`,{method:'POST',headers:{authorization:`Bearer ${control.secret}`},body:JSON.stringify({action:'quit'})});assert(response.ok);
assert.equal(await ended,0,readFileSync(installer+'.log','utf8'));
let after;for(let i=0;i<100;i++){await sleep(200);const current=JSON.parse(readFileSync(join(data,'test-control.json')));if(current.pid!==control.pid){after=current;break;}}
assert(after,'Application did not restart');
const status=await fetch(`http://127.0.0.1:${after.port}`,{method:'POST',headers:{authorization:`Bearer ${after.secret}`},body:JSON.stringify({action:'status'})});const state=await status.json();assert.equal(state.applicationVersion,version);
assert.equal(hash(join(data,'settings.json')),before.settings);assert.deepEqual(inventory(join(here,'.validation/installed-recordings')),before.recordings);
const result={version,time:new Date().toISOString(),method:'real signed NSIS and native helper; direct handoff, HTTPS download/confirmation tested separately',oldPID:control.pid,newPID:after.pid,settingsPreserved:true,recordingsPreserved:true,log:readFileSync(installer+'.log','utf8')};writeFileSync(join(here,'evidence/helper-handoff.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result,null,2));
