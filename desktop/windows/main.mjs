import {app,BrowserWindow,ipcMain,Menu,screen,desktopCapturer,dialog,shell,session} from 'electron';
import {join,resolve} from 'node:path';
import {readFileSync,writeFileSync,renameSync,mkdirSync,appendFileSync} from 'node:fs';
import {RecordingFiles} from './recording-files.mjs';
import {randomUUID} from 'node:crypto';
import {isBusy,defaults,validateConfig,fitRegion,outputSize,elapsed,sessionName} from './state.mjs';
import {createUpdater} from './updater.mjs';

app.setName('RecordReady');
if(process.env.RECORDREADY_TEST_DATA)app.setPath('userData',resolve(process.env.RECORDREADY_TEST_DATA));
app.commandLine.appendSwitch('autoplay-policy','no-user-gesture-required');
app.commandLine.appendSwitch('enable-features','WebRtcAllowWgcScreenCapturer');
if(!app.requestSingleInstanceLock())app.exit(0);
const windows={},pending=new Map();let files,config,state,region,updater,allowQuit=false,engineReady=false,engineWait,engineResolve,countdown,token,sessionDirectory,writingError='',monitoring=false;
const log=(event,detail='')=>{try{appendFileSync(join(app.getPath('userData'),'windows.log'),JSON.stringify({time:new Date().toISOString(),version:app.getVersion(),event,detail})+'\n')}catch{}};
function persist(){const path=join(app.getPath('userData'),'settings.json'),temp=path+'.tmp';writeFileSync(temp,JSON.stringify(config));renameSync(temp,path);}
const selectedDisplay=()=>screen.getAllDisplays().find(d=>String(d.id)===config.displayID);
function snapshot(){return {...config,...state,applicationVersion:app.getVersion(),elapsed:elapsed(state),regionUI:[region.x,region.y,region.width,region.height],directory:sessionDirectory||config.directory,catalog:{...state.catalog,displays:screen.getAllDisplays().map(d=>({id:String(d.id),name:d.label||`${d.size.width}×${d.size.height}`}))},devices:{camera:state.catalog?.cameras?.find(d=>d.id===config.cameraID)?.name||'',microphone:state.catalog?.microphones?.find(d=>d.id===config.microphoneID)?.name||''}};}
async function engine(action,value){await engineWait;return new Promise((resolve,reject)=>{const id=randomUUID(),timeout=setTimeout(()=>{pending.delete(id);reject(Error('capture_engine_timeout'))},action==='stop'?60000:30000);pending.set(id,{resolve,reject,timeout});windows.engine.webContents.send('rr:engine',{id,action,value});});}
function trusted(event){const w=BrowserWindow.fromWebContents(event.sender);if(!Object.values(windows).includes(w)||event.senderFrame!==event.sender.mainFrame)throw Error('untrusted_sender');return w;}
function sendConfig(){for(const w of Object.values(windows))if(!w.isDestroyed())w.webContents.send('rr:config',snapshot());}
function showSettings(section){const w=windows.settings;w.setSize(section==='beauty'?380:380,section==='beauty'?620:460);const b=windows.main.getBounds(),d=screen.getDisplayMatching(b).workArea;w.setPosition(Math.max(d.x,Math.min(b.x,d.x+d.width-380)),Math.max(d.y,b.y-470));w.webContents.send('rr:section',section);w.show();}
function cameraPosition(){const w=windows.engine;if(!config.camera||!state.cameraReady){w.hide();return;}const b=config.previewLayout==='fill'?region:{x:region.x+region.width-200,y:region.y+region.height-150,width:200,height:config.previewShape==='circle'?200:150};w.setBounds(b);w.showInactive();}
function layout(){for(const w of Object.values(windows))w.setContentProtection(isBusy(state));windows.frame.setBounds(region);windows.frame.setAspectRatio(config.width/config.height);windows.frame.setResizable(!isBusy(state));windows.frame.setIgnoreMouseEvents(isBusy(state));if(state.overlaysVisible)windows.frame.showInactive();else windows.frame.hide();const d=selectedDisplay()||screen.getPrimaryDisplay(),b=d.workArea;windows.region.setPosition(Math.max(b.x,Math.min(region.x,b.x+b.width-520)),Math.max(b.y,Math.min(region.y+region.height+8,b.y+b.height-100)));if(state.overlaysVisible&&!isBusy(state))windows.region.showInactive();else windows.region.hide();cameraPosition();sendConfig();}
async function monitor(){if(monitoring)throw Error('device_configuration_busy');monitoring=true;state.monitorError='';try{const result=await engine('monitor',config);Object.assign(state,result,{monitoringActive:true});if(config.camera&&!config.cameraID)config.cameraID=result.catalog.cameras[0]?.id||'';if(config.microphone&&!config.microphoneID)config.microphoneID=result.catalog.microphones[0]?.id||'';persist();cameraPosition();}catch(e){Object.assign(state,{cameraReady:false,microphoneReady:false,monitorError:e.message,monitoringActive:false});windows.engine.hide();throw e;}finally{monitoring=false;}}
async function closeHandles(){if(files)await files.close();}
async function start(){
 if(isBusy(state)||monitoring||updater.snapshot().phase==='installing')throw Error('session_busy');
 if(!selectedDisplay())throw Error('missing_display');
 state.phase='preparing';state.error='';state.result={};sessionDirectory=undefined;state.started=0;state.pausedAt=0;state.pausedMs=0;
 try{await monitor();state.phase='countdown';state.remaining=3;layout();countdown=setInterval(()=>{state.remaining--;if(state.remaining<=0){clearInterval(countdown);void beginCapture();}},1000);}catch(e){state.phase='failed';state.error=e.message;layout();throw e;}
}
async function beginCapture(){
 if(state.phase!=='countdown')return;state.phase='starting';token=randomUUID();writingError='';
 try{
  const display=selectedDisplay();if(!display)throw Error('missing_display');const sources=await desktopCapturer.getSources({types:['screen'],thumbnailSize:{width:0,height:0}});const source=sources.find(s=>s.display_id===config.displayID);if(!source)throw Error('missing_display');
  sessionDirectory=join(config.directory,sessionName());mkdirSync(sessionDirectory,{recursive:true});
  files=new RecordingFiles(sessionDirectory);await files.create(['screen',...(config.camera?['camera']:[])]);
  const result=await engine('start',{...config,region,displayBounds:display.bounds,sourceID:source.id,outputPixels:outputSize(config),cameraBounds:windows.engine.getBounds(),token});
  state.phase='recording';state.started=Date.now();state.result={outputPixels:outputSize(config),cameraOutputPixels:result.cameraPixels};layout();log('recording-started',{directory:sessionDirectory,output:outputSize(config)});
 }catch(e){await engine('stop').catch(()=>{});await closeHandles();state.phase='failed';state.error=e.message;state.result.fatalError=e.message;layout();log('recording-failed',e.message);}
}
async function stop(fatal=''){
 if(!['recording','paused'].includes(state.phase))throw Error('not_recording');const duration=elapsed(state);state.phase='saving';state.pausedAt=Date.now();layout();
 let result;try{result=await engine('stop');}catch(e){fatal=fatal||e.message;}fatal=fatal||result?.error||writingError;const saved=await files.finish(result?.results.filter(r=>r.bytes>0).map(r=>r.name)||[]);
 if(!config.camera)saved.camera='not-requested';const count=Object.values(saved).filter(x=>x==='saved').length;state.phase=count===(config.camera?2:1)?'saved':count?'partial':'failed';state.result={...state.result,saveResults:saved,fatalError:fatal||undefined,duration};state.error=fatal||(state.phase==='failed'?'mp4_encoder_no_output':'');layout();showSettings('results');log('recording-saved',{phase:state.phase,duration,results:saved});
}
let commandQueue=Promise.resolve();
function native(request){if(request.action==='status'||request.action==='update')return handleNative(request);const result=commandQueue.then(()=>handleNative(request));commandQueue=result.catch(()=>{});return result;}
async function handleNative(request){const {action,...args}=request;
 if(action==='update')return updater.operation(args.operation);
 if(action==='status')return snapshot();
 if(action==='interface'){for(const key of ['language','theme'])if(typeof args[key]==='string')config[key]=args[key];persist();sendConfig();}
 else if(action==='restore-session'){if(!state.restored){state.restored=true;state.catalog=await engine('catalog');await monitor();}}
 else if(action==='configure'){
  if(isBusy(state)||monitoring)throw Error('session_busy');const allowed=['width','height','quality','camera','microphone','cameraID','microphoneID','displayID','directory','mirror','previewShape','previewLayout','previewPosition'];if(Object.keys(args).some(k=>!allowed.includes(k)))throw Error('invalid_configuration');
  const old=config;config=validateConfig(config,args,screen.getAllDisplays());persist();if(args.width||args.height||args.displayID)region=fitRegion(selectedDisplay(),config.width,config.height);
  if(['camera','microphone','cameraID','microphoneID','quality'].some(k=>old[k]!==config[k]))await monitor();else await engine('config',config);layout();
 }
 else if(action==='area'){if(isBusy(state))throw Error('session_busy');state.overlaysVisible=!state.overlaysVisible;if(state.overlaysVisible)state.phase='ready';layout();}
 else if(action==='hide'){if(isBusy(state))throw Error('session_busy');state.overlaysVisible=false;layout();}
 else if(action==='show-prompt'){state.promptVisible=true;windows['prompt-text'].show();windows.prompter.show();sendConfig();}
 else if(action==='hide-prompt'){state.promptVisible=false;windows['prompt-text'].hide();windows.prompter.hide();}
 else if(action==='prompt'){
  if(args.fontSize!==undefined){if(!Number.isFinite(args.fontSize)||args.fontSize<24||args.fontSize>48)throw Error('invalid_font');config.fontSize=args.fontSize;}
  if(args.speed!==undefined){if(!Number.isFinite(args.speed)||args.speed<2||args.speed>100)throw Error('invalid_speed');config.promptSpeed=args.speed;}
  if(args.opacity!==undefined){if(!Number.isFinite(args.opacity)||args.opacity<0||args.opacity>1)throw Error('invalid_opacity');config.promptOpacity=args.opacity;}
  if(typeof args.text==='string'){if(args.text.length>200000)throw Error('script_too_long');config.text=args.text;state.playing=false;}
  if(typeof args.playing==='boolean'){state.playing=args.playing;state.promptStarted=true;}if(args.reset){state.playing=false;state.promptStarted=false;state.promptReset=(state.promptReset||0)+1;}persist();sendConfig();
 }
 else if(action==='move-overlay'){if(args.kind==='region'&&isBusy(state))throw Error('session_busy');if(!Number.isFinite(args.dx)||!Number.isFinite(args.dy))throw Error('invalid_position');if(args.kind==='region'){const d=selectedDisplay().bounds;region.x=Math.round(Math.max(d.x,Math.min(region.x+args.dx,d.x+d.width-region.width)));region.y=Math.round(Math.max(d.y,Math.min(region.y+args.dy,d.y+d.height-region.height)));layout();}else{const w=windows['prompt-text'],b=w.getBounds();w.setPosition(Math.round(b.x+args.dx),Math.round(b.y+args.dy));}}
 else if(action==='device-menu'){
  if(isBusy(state)||monitoring)throw Error('session_busy');const camera=args.kind==='camera',items=state.catalog[camera?'cameras':'microphones']||[],key=camera?'camera':'microphone',idKey=camera?'cameraID':'microphoneID';const zh=config.language==='zh-CN';
  Menu.buildFromTemplate([{label:zh?(camera?'不录制摄像头':'静音录制'):'Off',type:'radio',checked:!config[key],click:()=>void native({action:'configure',[key]:false}).catch(e=>{state.error=e.message})},...items.map(d=>({label:d.name,type:'radio',checked:config[key]&&config[idKey]===d.id,click:()=>void native({action:'configure',[key]:true,[idKey]:d.id}).catch(e=>{state.error=e.message})}))]).popup({window:windows.main});
 }
 else if(action==='quit'){if(isBusy(state))throw Error('session_busy');allowQuit=true;persist();app.quit();}
 else if(action==='start')await start();
 else if(action==='cancel'){if(state.phase!=='countdown')throw Error('not_counting_down');clearInterval(countdown);state.phase='ready';state.remaining=0;layout();}
 else if(action==='stop')await stop();
 else if(action==='pause'){if(state.phase!=='recording')throw Error('not_recording');await engine('pause');state.pausedAt=Date.now();state.phase='paused';}
 else if(action==='resume'){if(state.phase!=='paused')throw Error('not_paused');await engine('resume');state.pausedMs+=Date.now()-state.pausedAt;state.pausedAt=0;state.phase='recording';}
 else if(action==='open-folder'){const path=args.current?config.directory:sessionDirectory||config.directory;mkdirSync(path,{recursive:true});const error=await shell.openPath(path);if(error)throw Error(error);}
 else throw Error('unsupported_action');
 return snapshot();
}
function windowFor(label,{width,height,...options}){
 const w=new BrowserWindow({title:`RecordReady${label==='main'?'':' · '+label}`,width,height,show:false,frame:false,transparent:true,alwaysOnTop:true,resizable:false,skipTaskbar:label!=='main',...options,webPreferences:{preload:join(__dirname,'preload.cjs'),nodeIntegration:false,contextIsolation:true,sandbox:true,backgroundThrottling:false}});windows[label]=w;w.setContentProtection(false);w.webContents.setWindowOpenHandler(()=>({action:'deny'}));w.webContents.on('will-navigate',e=>e.preventDefault());w.webContents.on('render-process-gone',(_e,d)=>{log('renderer-failed',{label,...d});if(label==='engine'){state.error='capture_engine_failed';if(['recording','paused'].includes(state.phase))void stop('capture_engine_failed');}});
 w.on('page-title-updated',e=>e.preventDefault());
 w.on('close',e=>{if(allowQuit)return;e.preventDefault();if(label==='settings')w.hide();else showSettings('quit');});
 if(label==='engine')w.loadFile(join(__dirname,'engine.html'));else w.loadFile(join(__dirname,'ui/index.html'),{query:{view:label}});return w;
}
app.whenReady().then(async()=>{
 mkdirSync(app.getPath('userData'),{recursive:true});const display=screen.getPrimaryDisplay();config=defaults(join(app.getPath('videos'),'RecordReady'),display.id);try{config=validateConfig(config,JSON.parse(readFileSync(join(app.getPath('userData'),'settings.json'),'utf8')),screen.getAllDisplays());}catch(e){log('settings-defaults',e.message);}region=fitRegion(selectedDisplay()||display,config.width,config.height);state={phase:'idle',error:'',remaining:0,started:0,pausedMs:0,pausedAt:0,playing:false,level:0,result:{},catalog:{cameras:[],microphones:[]},overlaysVisible:false,promptVisible:false};
 updater=createUpdater({busy:()=>isBusy(state),allowExit:()=>{allowQuit=true;persist()},language:()=>config.language,log});engineWait=new Promise(resolve=>engineResolve=resolve);
 ipcMain.handle('rr:invoke',async(event,command,args={})=>{const w=trusted(event);
  if(command==='native_request')return native(args.request);
  if(command==='window-scale')return screen.getDisplayMatching(w.getBounds()).scaleFactor;
  if(command==='window-position'){const b=w.getBounds(),s=screen.getDisplayMatching(b).scaleFactor;return {x:b.x*s,y:b.y*s};}
  if(command==='show_settings'){showSettings(args.section);return;}
  if(command==='close_settings'){windows.settings.hide();windows[args.source||'main']?.focus();return;}
  if(command==='sync_overlays')return;
  if(command==='resize_toolbar'){const width=Math.max(320,Math.min(1100,Math.ceil(args.width))),height=Math.max(68,Math.min(220,Math.ceil(args.height)));windows.main.setSize(width,height);if(!windows.main.isVisible())windows.main.show();return;}
  if(command==='resize_settings_content')return;
  if(command==='place_recording_toolbar'){const b=selectedDisplay()?.workArea||display.workArea;windows.main.setPosition(Math.round(b.x+(b.width-windows.main.getBounds().width)/2),b.y+b.height-90);return;}
  if(command==='choose-directory'){const result=await dialog.showOpenDialog(w,{properties:['openDirectory','createDirectory']});return result.canceled?null:result.filePaths[0];}
  if(command==='request_exit'){showSettings('quit');return;}
  if(command==='quit_app'){if(isBusy(state))throw Error('session_busy');allowQuit=true;persist();app.quit();return;}
  throw Error('unsupported_command');
 });
 ipcMain.on('rr:engine-reply',(event,{id,value,error})=>{if(event.sender!==windows.engine?.webContents)return;const p=pending.get(id);if(!p)return;clearTimeout(p.timeout);pending.delete(id);if(error)p.reject(Error(error));else p.resolve(value);});
 ipcMain.on('rr:report',(event,value)=>{if(event.sender!==windows.engine?.webContents)return;if(value.engineReady){engineReady=true;engineResolve();}if(typeof value.level==='number')state.level=value.level;if(value.catalog)state.catalog=value.catalog;if(value.error){state.monitorError=value.error;log('capture-error',value.error);if(value.fatal&&['recording','paused'].includes(state.phase))void stop(value.error);}});
 ipcMain.handle('rr:chunk',async(event,id,name,bytes)=>{if(event.sender!==windows.engine?.webContents||id!==token||!files?.files.has(name)||!(bytes instanceof ArrayBuffer)||bytes.byteLength>64*1024*1024)throw Error('invalid_recording_chunk');try{await files.write(name,bytes);}catch(e){writingError=e.message;throw e;}});
 const b=display.workArea;windowFor('main',{width:850,height:84,x:Math.round(b.x+(b.width-850)/2),y:b.y+b.height-100});windowFor('settings',{width:380,height:460});windowFor('region',{width:520,height:100});windowFor('frame',{...region,resizable:true});windowFor('prompter',{width:740,height:48,x:b.x+100,y:b.y+80});windowFor('prompt-text',{width:740,height:240,x:b.x+100,y:b.y+128,resizable:true});windowFor('engine',{width:200,height:150,resizable:true});
 let adjusting=false;windows.frame.on('move',()=>{if(!isBusy(state)&&!adjusting){region=windows.frame.getBounds();sendConfig();}});windows.frame.on('resized',()=>{if(!isBusy(state)&&!adjusting){adjusting=true;region=windows.frame.getBounds();layout();adjusting=false;}});
 windows['prompt-text'].on('move',()=>{const p=windows['prompt-text'].getBounds();windows.prompter.setPosition(p.x,p.y-48);});
 windows.engine.on('moved',()=>{if(engineReady&&config.camera)void engine('config',{cameraBounds:windows.engine.getBounds()}).catch(()=>{});});
 windows.engine.on('resize',()=>{if(engineReady&&config.camera)void engine('config',{cameraBounds:windows.engine.getBounds()}).catch(()=>{});});
 windows.engine.webContents.on('context-menu',()=>{if(isBusy(state))return;Menu.buildFromTemplate([{label:config.language==='zh-CN'?'左右翻转':'Mirror',type:'checkbox',checked:config.mirror,click:()=>void native({action:'configure',mirror:!config.mirror})},{label:config.language==='zh-CN'?'圆形':'Circle',type:'checkbox',checked:config.previewShape==='circle',click:()=>void native({action:'configure',previewShape:config.previewShape==='circle'?'square':'circle'})},{label:config.language==='zh-CN'?'填满录制区域':'Fill recording area',type:'checkbox',checked:config.previewLayout==='fill',click:()=>void native({action:'configure',previewLayout:config.previewLayout==='fill'?'small':'fill'})}]).popup({window:windows.engine});});
 session.defaultSession.setPermissionRequestHandler((contents,permission,callback)=>callback(contents===windows.engine.webContents&&permission==='media'));
 session.defaultSession.setPermissionCheckHandler((contents,permission)=>contents===windows.engine.webContents&&['media','display-capture'].includes(permission));
 screen.on('display-removed',()=>{if(!selectedDisplay()){if(['recording','paused'].includes(state.phase))void stop('display_disconnected');else state.error='missing_display';}});
 app.on('second-instance',()=>windows.main.show());app.on('before-quit',e=>{if(!allowQuit){e.preventDefault();showSettings('quit');}});
 log('started',{platform:process.platform,arch:process.arch,executable:process.execPath});
 // Acceptance is opt-in, loopback-only and never enabled by the installer.
 if(process.env.RECORDREADY_TEST_CONTROL==='1'){
  const {createServer}=await import('node:http');const secret=randomUUID();const server=createServer(async(req,res)=>{if(req.headers.authorization!==`Bearer ${secret}`){res.writeHead(403).end();return;}try{let raw='';for await(const chunk of req){raw+=chunk;if(raw.length>1000000)throw Error('request_too_large');}const data=JSON.parse(raw||'{}');const result=await native(data);res.setHeader('content-type','application/json');res.end(JSON.stringify(result));}catch(e){res.writeHead(400).end(JSON.stringify({error:e.message}));}});server.listen(0,'127.0.0.1',()=>writeFileSync(join(app.getPath('userData'),'test-control.json'),JSON.stringify({port:server.address().port,secret,pid:process.pid})));app.on('will-quit',()=>server.close());
 }
}).catch(e=>{log('startup-failed',e.stack);app.exit(1)});
