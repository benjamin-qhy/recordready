import { useEffect, useRef, useState, useId } from 'react'
import { useTranslation } from 'react-i18next'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { open } from '@tauri-apps/plugin-dialog'
import { Video, Mic, MicOff, FolderOpen, Settings, FileText, Square, Circle, X, Play, Pause, RotateCcw, Scan, AlertCircle, Info, Minus, Plus, ChevronDown, VideoOff } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '@/components/ui/field'
import { RadioGroup, RadioGroupItem } from '@/components/ui/radio-group'
import { Separator } from '@/components/ui/separator'
import { Alert, AlertTitle, AlertDescription } from '@/components/ui/alert'
import { TooltipProvider } from '@/components/ui/tooltip'
import { desktop, native, section, returnFocus, menuAnchor } from '@/lib/native'
import { clock, initial, isLocked, recordingControlsOnly, validSize, deviceLabel } from '@/lib/session'
import type { Snapshot } from '@/lib/session'
import i18n from '@/lib/i18n'

const params = new URLSearchParams(location.search)
const view = params.get('view') ?? 'main'
const settingsView = view === 'settings'
document.documentElement.dataset.view = view
function themeApply(value: string) {
  const dark=value === 'dark' || (value === 'system' && matchMedia('(prefers-color-scheme: dark)').matches)
  document.documentElement.classList.toggle('dark',dark)
  if(desktop&&view==='main')void native('interface',{theme:dark?'dark':'light'}).catch(()=>{})
}
themeApply(localStorage.getItem('rr.theme') ?? 'system')

function Choice({label,value,onChange,items,disabled=false}:{label:string;value:string;onChange:(s:string)=>void;items:[string,string][];disabled?:boolean}) {
  return <Select value={value} onValueChange={onChange} disabled={disabled}><SelectTrigger aria-label={label} className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup>{items.map(([v,l])=><SelectItem key={v} value={v}>{l}</SelectItem>)}</SelectGroup></SelectContent></Select>
}

function Options({label,value,onChange,items,disabled=false}:{label:string;value:string;onChange:(s:string)=>void;items:[string,string][];disabled?:boolean}) {
  const id=useId()
  return <RadioGroup aria-label={label} value={value} onValueChange={onChange} disabled={disabled} className="option-group">{items.map(([v,l])=><label key={v} htmlFor={`${id}-${v}`} className="option"><RadioGroupItem id={`${id}-${v}`} value={v}/><span>{l}</span></label>)}</RadioGroup>
}

function aspectRatio(width:number,height:number) {
  const gcd=(a:number,b:number):number=>b?gcd(b,a%b):a
  const divisor=gcd(width,height)
  return `${width/divisor}:${height/divisor}`
}

function AudioLevel({value,label}:{value:number;label:string}) {
  const level=Math.max(0,Math.min(1,value))
  return <div className="audio-level" role="meter" aria-label={label} aria-valuemin={0} aria-valuemax={1} aria-valuenow={level}>{Array.from({length:12},(_,i)=><span key={i} className={level>(i/12)?'active':''} aria-hidden="true"/>)}</div>
}

function MicrophoneLevel({value,label,ready}:{value:number;label:string;ready:boolean}) {
  const level=ready?Math.max(0,Math.min(1,value)):0
  return <span className="microphone-meter" role="meter" aria-label={label} aria-valuemin={0} aria-valuemax={1} aria-valuenow={level} data-ready={ready}>{[.55,.8,1,.8,.55].map((weight,i)=><i key={i} style={{height:`${2+level*16*weight}px`}}/>)}</span>
}

export default function App() {
  const {t,i18n:translation} = useTranslation()
  const language=translation.language
  const [state,setState] = useState<Snapshot>(initial)
  const [error,setError] = useState('')
  const [pending,setPending] = useState(false)
  const [tab,setTab] = useState(params.get('section') ?? 'appearance')
  const [theme,setTheme] = useState(localStorage.getItem('rr.theme') ?? 'system')
  const [width,setWidth] = useState('1080'), [height,setHeight] = useState('1920')
  const [sizeError,setSizeError] = useState(false)
  const lastPhase = useRef('idle')
  const [customSize,setCustomSize]=useState(false)
  const drag=useRef<{x:number;y:number;targetX:number;targetY:number;busy:boolean}|null>(null)
  const sizeInitialized=useRef(false)
  const dirtyRef=useRef(false)
  const restored=useRef(false)
  const [dimensionsDirty,setDimensionsDirty]=useState(false)
  const dimensionRevision=useRef(0)
  dirtyRef.current=dimensionsDirty
  const locked = isLocked(state.phase)
  const recordingOnly = recordingControlsOnly(state.phase)
  const stateRef=useRef(state)
  stateRef.current=state

  useEffect(() => {
    let disposed=false, fetching=false
    const poll = async () => {
      if (!desktop || fetching) return
      fetching=true
      try {
        if(view==='main'&&!restored.current){
          await native('interface',{language:i18n.language,theme:document.documentElement.classList.contains('dark')?'dark':'light'})
          await native('restore-session');restored.current=true
        }
        const s=await native('status')
        if (!disposed) {
          setState(s)
          if(!sizeInitialized.current||!dirtyRef.current){setWidth(String(s.width));setHeight(String(s.height));sizeInitialized.current=true}
          if(view==='main') void invoke('sync_overlays').catch(e=>setError(String(e)))
          if (view==='main' && ['saved','partial','failed'].includes(s.phase) && lastPhase.current!==s.phase) void section('results')
          lastPhase.current=s.phase
        }
      } catch(e) { if(!disposed) setError(String(e)) }
      finally { fetching=false }
    }
    void poll(); const timer=setInterval(()=>void poll(),300)
    const sectionListener=desktop?listen<string>('section',e=>{setTab(e.payload);setError('');requestAnimationFrame(()=>document.querySelector<HTMLElement>('main button')?.focus())}):Promise.resolve(()=>{})
    const focusListener=desktop?listen('restore-focus',()=>returnFocus?.focus()):Promise.resolve(()=>{})
    const onStorage=()=>{const th=localStorage.getItem('rr.theme')??'system';setTheme(th);themeApply(th);const language=localStorage.getItem('rr.language');if(language)void i18n.changeLanguage(language)}
    const onEscape=(event:KeyboardEvent)=>{
      if(settingsView && event.key==='Escape' && !event.defaultPrevented){
        // Radix owns Escape while its child menu is open.
        if(document.querySelector('[role="listbox"]'))return
        event.preventDefault();void hide()
      }
    }
    window.addEventListener('keydown',onEscape)
    const media=matchMedia('(prefers-color-scheme: dark)')
    const onSystem=()=>themeApply(localStorage.getItem('rr.theme')??'system')
    window.addEventListener('storage',onStorage);media.addEventListener('change',onSystem)
    return ()=>{disposed=true;clearInterval(timer);void sectionListener.then(f=>f());void focusListener.then(f=>f());window.removeEventListener('keydown',onEscape);window.removeEventListener('storage',onStorage);media.removeEventListener('change',onSystem)}
  },[])

  async function run(action:string,args:Record<string,unknown>={}) {
    setError('');setPending(true)
    try { const s=await native(action,args);setState(s); return s }
    catch(e) {setError(e instanceof Error?e.message:String(e));return undefined}
    finally {setPending(false)}
  }
  async function startRecording() { await run('start') }
  async function openPrompt() { if(desktop) {await invoke('close_settings',{source:'main'});await native('interface',{language,theme:document.documentElement.classList.contains('dark')?'dark':'light'})} await run('show-prompt') }
  async function togglePrompt() { if(state.promptVisible) await run('hide-prompt'); else await openPrompt() }
  async function openArea() { if(desktop) await invoke('close_settings',{source:'main'}); await run('area') }
  async function deviceMenu(kind:'camera'|'audio',trigger:HTMLElement) {
    if(!desktop)return
    try { await invoke('close_settings',{source:'main'}); await run('device-menu',{kind,anchor:await menuAnchor(trigger)}) }
    catch(e){setError(String(e))}
  }
  function dragStart(event:React.PointerEvent<HTMLElement>) {
    if(!desktop||event.button!==0||(event.target as HTMLElement).closest('button,input,textarea,select,a,label,[role=combobox],[role=radio],[role=switch],[data-no-drag]'))return
    if(view==='region'||view==='prompter') {
      if(view==='region'&&locked)return
      event.currentTarget.setPointerCapture(event.pointerId)
      drag.current={x:event.screenX,y:event.screenY,targetX:event.screenX,targetY:event.screenY,busy:false}
    } else void getCurrentWindow().startDragging().catch(e=>setError(String(e)))
  }
  async function dragMove(event:React.PointerEvent<HTMLElement>) {
    const d=drag.current
    if(!d)return
    d.targetX=event.screenX;d.targetY=event.screenY
    if(d.busy)return
    d.busy=true
    try {
      while(d.x!==d.targetX||d.y!==d.targetY){
        const x=d.targetX,y=d.targetY,dx=x-d.x,dy=y-d.y
        d.x=x;d.y=y
        await native('move-overlay',{kind:view==='region'?'region':'prompter',dx,dy})
      }
    }catch(e){setError(String(e))}finally{d.busy=false}
  }
  const draggable={onPointerDown:dragStart,onPointerMove:dragMove,onPointerUp:()=>{drag.current=null},onPointerCancel:()=>{drag.current=null}}
  useEffect(()=>{
    if(!desktop||view!=='main')return
    const panel=document.querySelector('.main-panel')
    if(!panel)return
    const observer=new ResizeObserver(()=>{const rect=panel.getBoundingClientRect();void invoke('resize_toolbar',{width:Math.ceil(rect.width),height:Math.ceil(rect.height)}).then(()=>{
      const current=stateRef.current
      if(recordingControlsOnly(current.phase)&&current.regionUI) return invoke('place_recording_toolbar',{region:current.regionUI})
    }).catch(()=>{})})
    observer.observe(panel);return()=>observer.disconnect()
  },[])

  async function hide() { if(desktop) await invoke('close_settings',{source:localStorage.getItem('rr.settingsSource')});else location.search='' }
  useEffect(()=>{
    document.documentElement.dataset.section=settingsView?tab:''
    if(!desktop||!settingsView||!['saveLocation','appearance'].includes(tab))return
    const panel=document.querySelector('.settings')
    if(!panel)return
    const observer=new ResizeObserver(()=>void invoke('resize_settings_content',{section:tab,height:Math.ceil(panel.getBoundingClientRect().height)+16}).catch(()=>{}))
    observer.observe(panel);return()=>observer.disconnect()
  },[tab])
  useEffect(()=>{
    if(view!=='region'||!dimensionsDirty||locked||!desktop)return
    const revision=dimensionRevision.current
    const timer=setTimeout(()=>{
      const w=Number(width),h=Number(height)
      setSizeError(!validSize(w,h))
      if(validSize(w,h))void run('configure',{width:w,height:h}).then(s=>{if(s&&revision===dimensionRevision.current)setDimensionsDirty(false)})
    },400)
    return()=>clearTimeout(timer)
  },[width,height,dimensionsDirty,locked])
  function editDimension(axis:'width'|'height',value:string){
    dimensionRevision.current++;setDimensionsDirty(true);dirtyRef.current=true;setCustomSize(true);setSizeError(false)
    if(axis==='width')setWidth(value);else setHeight(value)
  }
  const deviceItems=(kind:'cameras'|'microphones'|'displays',selected:string):[string,string][]=>{
    const values=state.catalog?.[kind]??[]
    const items:[string,string][]=values.map(d=>[d.id,d.name])
    if(kind!=='displays')items.unshift(['default',t('defaultDevice')])
    if(selected && selected!=='default' && !values.some(d=>d.id===selected))items.push([selected,t('missingSelection')])
    return items
  }
  useEffect(()=>{if(desktop&&view==='main')void native('interface',{language,theme:document.documentElement.classList.contains('dark')?'dark':'light'}).catch(e=>setError(String(e)))},[language])
  const errorPanel = error || (view==='prompter'?'':state.error) || (view==='main'?state.monitorError:'')
  const recorderButton = recordingOnly ? <Button size="sm" variant="destructive" onClick={()=>void run('stop')}><Square data-icon="inline-start"/>{t('stop')}</Button>
    :state.phase==='countdown'?<Button size="sm" variant="outline" onClick={()=>void run('cancel')}>{t('cancel')} · {state.remaining}</Button>
    :<Button size="sm" disabled={!desktop||pending||locked||(view==='region'&&(dimensionsDirty||sizeError))} onClick={()=>void startRecording()}><Circle data-icon="inline-start"/>{t(locked?state.phase:'start')}</Button>
  const cameraName=state.camera?deviceLabel(state.catalog?.cameras,state.cameraID,state.defaultCameraID,t('defaultDevice'),t('missingSelection')):t('cameraOff')
  const audioName=state.microphone?deviceLabel(state.catalog?.microphones,state.microphoneID,state.defaultMicrophoneID,t('defaultDevice'),t('missingSelection')):t('silent')
  const openSettings=(name:string,element:HTMLElement)=>void section(name,element)

  const ratioOptions=[[1080,1920],[1920,1080],[1080,1440],[1080,1350],[1080,1080],[1440,1080]] as const
  const regionMessage=sizeError?t('invalid_size'):errorPanel?t(errorPanel,{defaultValue:errorPanel}):''
  if(view==='region') return <main className="region-panel region-config-toolbar" {...draggable}>
    <div className="region-options"><select aria-label={t('ratio')} disabled={locked||pending} value={customSize?'custom':ratioOptions.some(([w,h])=>aspectRatio(w,h)===aspectRatio(state.width,state.height))?aspectRatio(state.width,state.height):'custom'} onChange={e=>{dimensionRevision.current++;setDimensionsDirty(false);if(e.target.value==='custom'){setWidth(String(state.width));setHeight(String(state.height));setCustomSize(true);return}const [w,h]=ratioOptions.find(([w,h])=>aspectRatio(w,h)===e.target.value)!;setWidth(String(w));setHeight(String(h));setSizeError(false);setCustomSize(false);void run('configure',{width:w,height:h})}}>{ratioOptions.map(([w,h])=><option key={`${w}x${h}`} value={aspectRatio(w,h)}>{aspectRatio(w,h)}</option>)}<option value="custom">{t('custom')}</option></select></div>
    <div className="region-custom"><label><span>{language==='zh-CN'?'宽':'W'}</span><Input aria-label={t('width')} type="number" min={240} max={3840} step={2} value={width} disabled={locked} onChange={e=>editDimension('width',e.target.value)}/></label><span className="dimension-times">×</span><label><span>{language==='zh-CN'?'高':'H'}</span><Input aria-label={t('height')} type="number" min={240} max={3840} step={2} value={height} disabled={locked} onChange={e=>editDimension('height',e.target.value)}/></label></div>
    <div className="region-start">{recorderButton}</div>
    <Button className="window-close" variant="ghost" size="icon-sm" aria-label={t('cancelArea')} disabled={locked||pending} onClick={()=>void run('hide')}><X/></Button>
    {regionMessage&&<p className="compact-error region-error" role="alert"><AlertCircle/>{regionMessage}</p>}
  </main>
  if(view==='prompter') return <TooltipProvider><main className="prompt-toolbar" style={{'--prompt-opacity':state.promptOpacity??1} as React.CSSProperties} {...draggable}>
    <div className="prompt-adjust"><span className="adjust-label">{t('font')}</span><Button variant="ghost" size="icon-xs" aria-label={t('fontDown')} title={t('fontDown')} disabled={!desktop||(state.fontSize??32)<=24} onClick={()=>void run('prompt',{fontSize:(state.fontSize??32)-2})}><Minus/></Button><select aria-label={t('font')} value={state.fontSize??32} onChange={e=>void run('prompt',{fontSize:Number(e.target.value)})}>{Array.from({length:13},(_,i)=>24+i*2).map(n=><option key={n}>{n}</option>)}</select><Button variant="ghost" size="icon-xs" aria-label={t('fontUp')} title={t('fontUp')} disabled={!desktop||(state.fontSize??32)>=48} onClick={()=>void run('prompt',{fontSize:(state.fontSize??32)+2})}><Plus/></Button></div>
    <div className="prompt-adjust"><span className="adjust-label">{t('speed')}</span><Button variant="ghost" size="icon-xs" aria-label={t('speedDown')} title={t('speedDown')} disabled={!desktop||(state.promptSpeed??24)<=2} onClick={()=>void run('prompt',{speed:Math.max(2,(state.promptSpeed??24)-2)})}><Minus/></Button><select aria-label={t('speed')} title="pt/s" value={state.promptSpeed??24} onChange={e=>void run('prompt',{speed:Number(e.target.value)})}>{[...new Set([2,4,8,12,16,20,24,30,40,50,60,80,100,state.promptSpeed??24])].sort((a,b)=>a-b).map(n=><option key={n}>{n}</option>)}</select><Button variant="ghost" size="icon-xs" aria-label={t('speedUp')} title={t('speedUp')} disabled={!desktop||(state.promptSpeed??24)>=100} onClick={()=>void run('prompt',{speed:Math.min(100,(state.promptSpeed??24)+2)})}><Plus/></Button></div>
    <div className="prompt-adjust opacity-control"><label htmlFor="prompt-opacity">{t('opacity')}</label><input id="prompt-opacity" type="range" min="0" max="100" step="5" value={Math.round((state.promptOpacity??1)*100)} onChange={e=>void run('prompt',{opacity:Number(e.target.value)/100})}/><span>{Math.round((state.promptOpacity??1)*100)}%</span></div>
    <span className="prompt-action"><Button variant="ghost" disabled={!desktop} onClick={()=>void run('prompt',{reset:true})}><RotateCcw data-icon="inline-start"/>{t('reset')}</Button></span>
    <span className="prompt-action"><Button disabled={!desktop} onClick={()=>void run('prompt',{playing:!state.playing})}>{state.playing?<Pause data-icon="inline-start"/>:<Play data-icon="inline-start"/>}{t(state.playing?'promptPause':state.promptStarted?'promptResume':'promptStart')}</Button></span>
    <span className="prompt-action"><Button className="window-close" variant="ghost" size="icon-sm" aria-label={t('close')} onClick={()=>void run('hide-prompt')}><X/></Button></span>
    {errorPanel&&<p role="alert">{t(errorPanel,{defaultValue:errorPanel})}</p>}
  </main></TooltipProvider>

  if(!settingsView) return <TooltipProvider><main className="main-panel" {...draggable}>
    {!recordingOnly&&<nav className="toolbar" aria-label={t('recordingControls')}>
      <Button className="window-close" variant="ghost" size="icon-sm" aria-label={t('exit')} onClick={()=>void invoke('request_exit').catch(e=>setError(String(e)))}><X/></Button>
      <Separator orientation="vertical"/>
      <Button className="nav-item area-entry" aria-pressed={!!state.overlaysVisible} variant="ghost" disabled={locked||pending||!desktop} onClick={()=>void openArea()}><Scan/><span>{t('area')}</span></Button>
      <Separator orientation="vertical"/>
      <Button className="nav-device" variant="ghost" aria-label={`${t('video')} · ${cameraName}`} title={cameraName} disabled={!desktop||pending} onClick={e=>void deviceMenu('camera',e.currentTarget)}>{state.camera?<Video/>:<VideoOff/>}<span>{cameraName}</span><ChevronDown/></Button>
      <Button className="nav-device" variant="ghost" aria-label={`${t('voice')} · ${audioName}`} title={audioName} disabled={!desktop||pending} onClick={e=>void deviceMenu('audio',e.currentTarget)}>{state.microphone?<Mic/>:<MicOff/>}<span>{audioName}</span>{state.microphone&&<MicrophoneLevel value={state.level??0} ready={!!state.microphoneReady} label={t('inputLevel')}/>}<ChevronDown/></Button>
      <Button className="nav-item" aria-pressed={!!state.promptVisible} variant="ghost" onClick={()=>void openPrompt()}><FileText/><span>{t('scriptNav')}</span></Button>
      <Button className="nav-item" variant="ghost" onClick={e=>openSettings('saveLocation',e.currentTarget)}><FolderOpen/><span>{t('saveLocation')}</span></Button>
      <Button className="nav-item" variant="ghost" onClick={e=>openSettings('appearance',e.currentTarget)}><Settings/><span>{t('settingsNav')}</span></Button>
    </nav>}
    {recordingOnly&&<nav className="recording-widget recording-toolbar" aria-label={t('recordingControls')} {...draggable}>
      <div className="status" role="status"><span className={`dot ${state.phase==='recording'?'recording':'paused'}`}/>{t(state.phase)}</div>
      <span className="clock">{clock(state.elapsed)}</span>
      <AudioLevel value={state.level??0} label={t('inputLevel')}/>
      <Button variant="ghost" size="sm" onClick={()=>void run(state.phase==='paused'?'resume':'pause')}>{state.phase==='paused'?<Play data-icon="inline-start"/>:<Pause data-icon="inline-start"/>}{t(state.phase==='paused'?'resumeRecording':'pauseRecording')}</Button>
      <Button variant="ghost" size="sm" aria-pressed={!!state.promptVisible} onClick={()=>void togglePrompt()}><FileText data-icon="inline-start"/>{t('scriptNav')}</Button>
      {recorderButton}
    </nav>}
    {locked&&!recordingOnly&&<div className="recording-widget" {...draggable}><div className="status" role="status"><span className="dot"/>{t(state.phase)}</div><span className="clock">{clock(state.elapsed)}</span><AudioLevel value={state.level??0} label={t('inputLevel')}/>{recorderButton}</div>}
    {['saved','partial','failed'].includes(state.phase)&&<Button className="result-entry" variant="secondary" size="sm" onClick={e=>openSettings('results',e.currentTarget)}>{t(state.phase)}<FolderOpen/></Button>}
    {errorPanel&&<p className="compact-error" role="alert">{t(errorPanel,{defaultValue:errorPanel})}</p>}
    {!desktop&&<p className="browser-note">{t('nativeRequired')}</p>}
  </main></TooltipProvider>

  return <TooltipProvider><div className="settings-shell"><main className={`settings settings-${tab}`} role={tab==='quit'?'alertdialog':'dialog'} aria-labelledby="settings-title" {...draggable}>
    <header><h1 id="settings-title">{t(tab)}</h1><Button className="window-close" variant="ghost" size="icon" aria-label={t('close')} onClick={()=>void hide()}><X/></Button></header>

    {!desktop&&<Alert><AlertDescription>{t('nativeRequired')}</AlertDescription></Alert>}
    {errorPanel&&<Alert variant="destructive"><AlertCircle/><AlertTitle>{t('error')}</AlertTitle><AlertDescription>{t(errorPanel,{defaultValue:errorPanel})}</AlertDescription></Alert>}
    {locked&&!['appearance','quit','results','script'].includes(tab)&&<p className="helper">{t('locked')}</p>}
    {tab==='appearance'&&<FieldGroup><Field><FieldLabel>{t('display')}</FieldLabel><Choice label={t('display')} value={state.displayID??''} disabled={locked} onChange={displayID=>void run('configure',{displayID})} items={deviceItems('displays',state.displayID??'')}/></Field>
      <Field><FieldLabel>{t('theme')}</FieldLabel><Options label={t('theme')} value={theme} onChange={v=>{setTheme(v);localStorage.setItem('rr.theme',v);themeApply(v)}} items={['system','light','dark'].map(v=>[v,t(v)])}/>{theme==='system'&&<FieldDescription>{t('currentSystem',{mode:t(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light')})}</FieldDescription>}</Field>
      <Separator/><Field><FieldLabel>{t('language')}</FieldLabel><Choice label={t('language')} value={i18n.language} onChange={v=>{localStorage.setItem('rr.language',v);void i18n.changeLanguage(v)}} items={[["zh-CN","简体中文"],["en","English"]]}/></Field><p className="helper info-line"><Info aria-hidden="true"/>{t('autoSaved')}</p>
    </FieldGroup>}
    {tab==='saveLocation'&&<FieldGroup><Field><FieldLabel>{t('saveLocation')}</FieldLabel><p className="helper save-path" title={state.directory}>{state.directory}</p><Button variant="outline" disabled={locked||!desktop} onClick={async()=>{const path=await open({directory:true,multiple:false});if(path)await run('configure',{directory:path})}}>{t('choose')}</Button></Field><Button variant="outline" disabled={!desktop} onClick={()=>void run('open-folder',{current:true})}><FolderOpen data-icon="inline-start"/>{t('openFolder')}</Button><p className="helper">{t('saveHelp')}</p></FieldGroup>}
    {tab==='results'&&<FieldGroup>
      {state.result.fatalError&&<Alert variant="destructive"><AlertTitle>{t('interrupted')}</AlertTitle><AlertDescription>{state.result.fatalError}</AlertDescription></Alert>}
      {Object.entries(state.result.saveResults??{}).filter(([,v])=>v!=='not-requested').map(([name,status])=><div className="file-result" key={name}><strong>{t(name==='screen'?'screen':'cameraFile')}</strong><span>{name}{status==='saved'?'.mp4':'.partial.mp4'} · {status==='saved'?t('saved'):status}</span><span className="helper">{(name==='screen'?state.result.outputPixels:state.result.cameraOutputPixels)?.join(' × ')} · {clock((name==='screen'?state.result.screen:state.result.camera)?.lastVideoPTS??0)}</span></div>)}
      <p className="helper break-all">{state.directory}</p><Button variant="outline" disabled={!desktop} onClick={()=>void run('open-folder')}><FolderOpen data-icon="inline-start"/>{t('openFolder')}</Button><Button disabled={locked||pending||!desktop} onClick={async()=>{await hide();await openArea()}}>{t('again')}</Button>
    </FieldGroup>}
    {tab==='quit'&&<FieldGroup><p>{t(locked?'quitHelp':'quitConfirm')}</p><Button variant="outline" onClick={()=>void hide()}>{t('cancel')}</Button>{recordingControlsOnly(state.phase)&&<Button onClick={()=>void run('stop')}>{t('stopSave')}</Button>}{state.phase==='countdown'&&<Button onClick={()=>void run('cancel')}>{t('cancel')}</Button>}<Button variant="destructive" disabled={locked||!desktop} onClick={()=>void invoke('quit_app').catch(e=>setError(String(e)))}>{t('exit')}</Button></FieldGroup>}
  </main></div></TooltipProvider>
}
