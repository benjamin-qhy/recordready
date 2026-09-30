import {app,dialog} from 'electron';
import {NsisUpdater} from 'electron-updater/out/NsisUpdater.js';
import {randomUUID} from 'node:crypto';
import {readFileSync,mkdirSync,copyFileSync} from 'node:fs';
import {access} from 'node:fs/promises';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {validateFeed} from './update-manifest.mjs';
import {signedProvider} from './signed-provider.mjs';
import {verifyInstaller} from './installer-integrity.mjs';
export {verifyInstaller};
export function createUpdater({busy,allowExit,language,log}){
 let state={phase:'unavailable',version:app.getVersion()},transport,info,file,cancellation,generation=0,installing=false;
 const snapshot=()=>({...state});
 try{
  const config=JSON.parse(readFileSync(join(process.resourcesPath,'update-config.json'),'utf8'));validateFeed(config.feedUrl,config.validation===true);
  transport=new NsisUpdater();transport.setFeedURL({provider:'custom',updateProvider:signedProvider(config)});transport.autoDownload=false;transport.autoInstallOnAppQuit=false;transport.allowDowngrade=false;transport.disableWebInstaller=true;transport.disableDifferentialDownload=false;
  transport.logger={info:m=>log('update',String(m)),warn:m=>log('update-warning',String(m)),error:m=>log('update-error',String(m))};
  transport.on('error',e=>log('update-error',e.message));transport.on('download-progress',p=>{if(state.phase==='downloading'){state.received=p.transferred;state.total=p.total;}});
  state.phase='idle';
 }catch(e){log('update-unavailable',e.message);}
 async function operation(op){
  if(op==='status'||op==='before-quit')return snapshot();
  if(installing)throw Error('update_busy');
  if(!transport)throw Error('updates_unavailable');
  if(op==='cancel'){generation++;cancellation?.cancel();state={phase:'idle',version:app.getVersion()};info=file=undefined;return snapshot();}
  if(op==='later')return snapshot();
  if(op==='check'){
   if(['checking','downloading','preparing','installing'].includes(state.phase))throw Error('update_busy');
   const mine=++generation;state={phase:'checking',version:app.getVersion()};info=file=undefined;
   void (async()=>{try{const result=await transport.checkForUpdates();if(mine!==generation)return;cancellation=result?.cancellationToken;if(!result)throw Error('update_check_unavailable');info=result.updateInfo;state.phase=result.isUpdateAvailable?'available':'current';state.availableVersion=info.version;state.message='';}catch(e){if(mine===generation){state.phase='error';state.message=e.message;}}})();return snapshot();
  }
  if(op==='download'){
   if(state.phase!=='available'||!info)throw Error('update_not_available');
   const mine=++generation;state.phase='downloading';state.received=0;state.total=info.files[0].size;
   void (async()=>{try{const files=await transport.downloadUpdate(cancellation);if(mine!==generation)return;if(files.length!==1)throw Error('invalid_installer_count');state.phase='preparing';await verifyInstaller(files[0],info.files[0]);if(mine!==generation)return;file=files[0];state.phase='ready';}catch(e){if(mine===generation){state.phase='error';state.message=e.message;}}})();return snapshot();
  }
  if(op==='install'){
   if(state.phase!=='ready'||!file||installing)throw Error('update_not_ready');if(busy())throw Error('session_busy');installing=true;
   try{
    const zh=language()==='zh-CN';const answer=await dialog.showMessageBox({type:'question',title:'RecordReady',message:zh?'现在退出并安装更新？已保存的录像和设置会保留。':'Quit and install the update? Saved recordings and settings will be kept.',buttons:zh?['稍后','重启安装']:['Later','Restart and install'],defaultId:0,cancelId:0});
    if(answer.response!==1)return snapshot();if(busy())throw Error('session_busy');await verifyInstaller(file,info.files[0]);if(busy())throw Error('session_busy');
    // Freeze new recordings before handing the verified installer to the helper.
    state.phase='installing';const cache=join(app.getPath('userData'),'updates',randomUUID());mkdirSync(cache,{recursive:true});const runner=join(cache,'update-runner.exe'),pending=join(cache,'setup.exe');copyFileSync(join(process.resourcesPath,'update-runner.exe'),runner);copyFileSync(file,pending);await verifyInstaller(pending,info.files[0]);
    const child=spawn(runner,[String(process.pid),pending,process.execPath],{detached:true,stdio:'ignore',windowsHide:true});await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject)});child.unref();
    let ready=false;for(let i=0;i<100;i++){try{await access(pending+'.ready');ready=true;break;}catch{}await new Promise(resolve=>setTimeout(resolve,50));}if(!ready)throw Error('installer_helper_not_ready');
    log('install-requested',state.availableVersion);allowExit();app.quit();return snapshot();
   }catch(e){state.phase='ready';throw e;}finally{installing=false;}
  }
  throw Error('unknown_update_operation');
 }
 return {operation,snapshot};
}
