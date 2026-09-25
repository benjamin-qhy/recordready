import { useEffect, useRef, useState, useId } from 'react'
import { useTranslation } from 'react-i18next'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { open } from '@tauri-apps/plugin-dialog'
import { Video, Mic, MicOff, FolderOpen, Settings, FileText, Square, Circle, X, Play, Pause, RotateCcw, Scan, GripVertical, AlertCircle } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Switch } from '@/components/ui/switch'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Field, FieldGroup, FieldLabel, FieldDescription } from '@/components/ui/field'
import { RadioGroup, RadioGroupItem } from '@/components/ui/radio-group'
import { Separator } from '@/components/ui/separator'
import { Alert, AlertTitle, AlertDescription } from '@/components/ui/alert'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import { desktop, native, section, returnFocus } from '@/lib/native'
import { clock, initial, isLocked, presets, validSize } from '@/lib/session'
import type { Snapshot } from '@/lib/session'
import i18n from '@/lib/i18n'

const params = new URLSearchParams(location.search)
const view = params.get('view') ?? 'main'
const settingsView = view === 'settings'
document.documentElement.dataset.view = view
function themeApply(value: string) {
  document.documentElement.classList.toggle('dark',value === 'dark' || (value === 'system' && matchMedia('(prefers-color-scheme: dark)').matches))
}
themeApply(localStorage.getItem('rr.theme') ?? 'system')

function Choice({label,value,onChange,items,disabled=false}:{label:string;value:string;onChange:(s:string)=>void;items:[string,string][];disabled?:boolean}) {
  return <Select value={value} onValueChange={onChange} disabled={disabled}><SelectTrigger aria-label={label} className="w-full"><SelectValue /></SelectTrigger><SelectContent><SelectGroup>{items.map(([v,l])=><SelectItem key={v} value={v}>{l}</SelectItem>)}</SelectGroup></SelectContent></Select>
}

function Options({label,value,onChange,items,disabled=false}:{label:string;value:string;onChange:(s:string)=>void;items:[string,string][];disabled?:boolean}) {
  const id=useId()
  return <RadioGroup aria-label={label} value={value} onValueChange={onChange} disabled={disabled} className="option-group">{items.map(([v,l])=><label key={v} htmlFor={`${id}-${v}`} className="option"><RadioGroupItem id={`${id}-${v}`} value={v}/><span>{l}</span></label>)}</RadioGroup>
}

export default function App() {
  const {t,i18n:translation} = useTranslation()
  const language=translation.language
  const [state,setState] = useState<Snapshot>(initial)
  const [error,setError] = useState('')
  const [pending,setPending] = useState(false)
  const [tab,setTab] = useState(params.get('section') ?? 'appearance')
  const [theme,setTheme] = useState(localStorage.getItem('rr.theme') ?? 'system')
  const [script,setScript] = useState(localStorage.getItem('rr.script') ?? '')
  const [title,setTitle] = useState(localStorage.getItem('rr.title') ?? '')
  const [width,setWidth] = useState('1080'), [height,setHeight] = useState('1920')
  const [sizeError,setSizeError] = useState(false)
  const lastPhase = useRef('idle')
  const sizeInitialized=useRef(false)
  const locked = isLocked(state.phase)

  useEffect(() => {
    let disposed=false, fetching=false
    const poll = async () => {
      if (!desktop || fetching) return
      fetching=true
      try {
        const s=await native('status')
        if (!disposed) {
          setState(s)
          if(!sizeInitialized.current){setWidth(String(s.width));setHeight(String(s.height));sizeInitialized.current=true}
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
    const onStorage=()=>{const th=localStorage.getItem('rr.theme')??'system';setTheme(th);themeApply(th);setScript(localStorage.getItem('rr.script')??'');setTitle(localStorage.getItem('rr.title')??'');const language=localStorage.getItem('rr.language');if(language)void i18n.changeLanguage(language)}
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
  async function prepare() { if(await run('script',{text:localStorage.getItem('rr.script')??''})) await run('prepare') }
  async function hide() { if(desktop) await invoke('close_settings',{source:localStorage.getItem('rr.settingsSource')});else location.search='' }
  useEffect(()=>{
    if(view!=='settings'||tab!=='script'||locked||!desktop) return
    const timer=setTimeout(()=>{void native('script',{text:script}).catch(e=>setError(String(e)))},250)
    return ()=>clearTimeout(timer)
  },[script,tab,locked])
  const deviceItems=(kind:'cameras'|'microphones'|'displays',selected:string):[string,string][]=>{
    const values=state.catalog?.[kind]??[]
    const items:[string,string][]=values.map(d=>[d.id,d.name])
    if(kind!=='displays')items.unshift(['default',t('defaultDevice')])
    if(selected && selected!=='default' && !values.some(d=>d.id===selected))items.push([selected,t('missingSelection')])
    return items
  }
  useEffect(()=>{if(desktop&&view==='main')void native('interface',{language}).catch(e=>setError(String(e)))},[language])
  const configurationDisabled=locked||pending||!desktop
  const errorPanel = error || state.error
  const icon = (name:string, Icon:typeof Video) => <Tooltip><TooltipTrigger asChild><Button variant="secondary" size="icon-lg" aria-label={t(name)} onClick={e=>void section(name==='saveLocation'?'results':name,e.currentTarget)}><Icon /></Button></TooltipTrigger><TooltipContent>{t(name)}</TooltipContent></Tooltip>
  const recorderButton = state.phase==='recording' ? <Button size="lg" variant="destructive" onClick={()=>void run('stop')}><Square data-icon="inline-start"/>{t('stop')}</Button>
    :state.phase==='countdown'?<Button size="lg" variant="outline" onClick={()=>void run('cancel')}>{t('cancel')} · {state.remaining}</Button>
    :state.phase==='ready'?<Button size="lg" disabled={pending} onClick={()=>void run('start')}><Circle data-icon="inline-start"/>{t('start')}</Button>
    :<Button size="lg" disabled={!desktop||pending||locked} onClick={()=>void prepare()}>{t(locked?state.phase:'prepare')}</Button>

  if(view==='region') return <main className="region-toolbar"><Button variant="ghost" disabled={locked} onClick={e=>void section('size',e.currentTarget)}><Scan data-icon="inline-start"/>{state.width} × {state.height}</Button><Button variant="ghost" disabled={locked} onClick={e=>void section('size',e.currentTarget)}>{t('size')}</Button></main>
  if(view==='prompter') return <TooltipProvider><main className="prompt-toolbar dark">
    <Button variant="ghost" disabled={locked} onClick={e=>void section('script',e.currentTarget)}><FileText data-icon="inline-start"/>{t('script')}</Button>
    <Field><FieldLabel>{t('font')}</FieldLabel><select aria-label={t('font')} value={state.fontSize??32} disabled={!desktop} onChange={e=>void run('prompt',{fontSize:Number(e.target.value)})}>{[24,28,32,36,40,48].map(n=><option key={n} value={n}>{n}px</option>)}</select></Field>
    <Field><FieldLabel>{t('speed')}</FieldLabel><select aria-label={t('speed')} value={state.promptSpeed??24} disabled={!desktop} onChange={e=>void run('prompt',{speed:Number(e.target.value)})}>{[[12,'slow'],[24,'normal'],[40,'fast']].map(([v,k])=><option key={v} value={v}>{t(String(k))}</option>)}</select></Field>
    <Button variant="ghost" disabled={!desktop} onClick={()=>void run('prompt',{reset:true})}><RotateCcw data-icon="inline-start"/>{t('reset')}</Button>
    <Button disabled={!desktop} onClick={()=>void run('prompt',{playing:!state.playing})}>{state.playing?<Pause data-icon="inline-start"/>:<Play data-icon="inline-start"/>}{t(state.playing?'promptPause':state.promptStarted?'promptResume':'promptStart')}</Button>
    {errorPanel&&<p role="alert">{t(errorPanel,{defaultValue:errorPanel})}</p>}
  </main></TooltipProvider>

  if(!settingsView) return <TooltipProvider><main>
    <div className="toolbar">
      <Button variant="ghost" size="icon" aria-label={t('move')} onMouseDown={()=>{if(desktop)void getCurrentWindow().startDragging()}}><GripVertical/></Button>
      <div className="status" role="status"><span className={`dot ${state.phase==='recording'?'recording':''}`}/>{t(state.phase)}</div>
      <span className="clock">{clock(state.elapsed)}</span><Separator orientation="vertical" className="h-8"/>
      {icon('camera',Video)}{icon('audio',state.microphone?Mic:MicOff)}
      <meter min={0} max={1} value={state.level??0} aria-label={t('microphone')} className="w-12"/>
      {state.phase==='idle'&&<>{icon('size',Scan)}{icon('script',FileText)}</>}
      {icon('saveLocation',FolderOpen)}{icon('appearance',Settings)}
      <div className="ml-auto">{recorderButton}</div>
    </div>
    <div className="toolbar-meta"><span>{state.width} × {state.height}{!state.microphone?` · ${t('silent')}`:''}</span><span>{errorPanel?t(errorPanel,{defaultValue:errorPanel}):''}</span></div>
    {!desktop&&<Alert className="browser-note"><AlertCircle/><AlertDescription>{t('nativeRequired')}</AlertDescription></Alert>}
  </main></TooltipProvider>

  return <TooltipProvider><main className="settings" role={tab==='quit'?'alertdialog':'dialog'} aria-labelledby="settings-title">
    <header><h1 id="settings-title">{t(tab)}</h1><Button variant="ghost" size="icon" aria-label={t('close')} onClick={()=>void hide()}><X/></Button></header>

    {!desktop&&<Alert><AlertDescription>{t('nativeRequired')}</AlertDescription></Alert>}
    {errorPanel&&<Alert variant="destructive"><AlertCircle/><AlertTitle>{t('error')}</AlertTitle><AlertDescription>{t(errorPanel,{defaultValue:errorPanel})}</AlertDescription></Alert>}
    {locked&&!['appearance','quit','results','script'].includes(tab)&&<p className="helper">{t('locked')}</p>}
    {tab==='camera'&&<FieldGroup>
      <Field orientation="horizontal"><FieldLabel htmlFor="camera">{t('cameraEnabled')}</FieldLabel><Switch id="camera" checked={state.camera} disabled={configurationDisabled} onCheckedChange={camera=>void run('configure',{camera})}/></Field>
      <Separator/><Field><FieldLabel>{t('device')}</FieldLabel><Choice label={t('device')} value={state.cameraID||'default'} disabled={configurationDisabled||!state.camera} onChange={v=>void run('configure',{cameraID:v==='default'?'':v})} items={deviceItems('cameras',state.cameraID??'')}/></Field>
      <Separator/><Field><FieldLabel>{t('previewLayout')}</FieldLabel><Options label={t('previewLayout')} value={state.previewLayout??'small'} disabled={!desktop||!state.camera||pending} onChange={layout=>void run('preview',{layout})} items={[["small",t('small')],["fill",t('fill')]]}/></Field>
      <Field><FieldLabel>{t('previewPosition')}</FieldLabel><Options label={t('previewPosition')} value={state.previewPosition??'bottom-right'} disabled={!desktop||!state.camera||state.previewLayout==='fill'||pending} onChange={position=>void run('preview',{position})} items={[["top-left",t('topLeft')],["top-right",t('topRight')],["bottom-left",t('bottomLeft')],["bottom-right",t('bottomRight')]]}/><FieldDescription>{state.previewPosition==='manual'?`${t('manual')} · `:''}{t('dragPreview')}</FieldDescription></Field>
      <Separator/><Field orientation="horizontal"><FieldLabel htmlFor="mirror">{t('mirror')}</FieldLabel><Switch id="mirror" checked={state.mirror??false} disabled={!desktop||!state.camera||pending} onCheckedChange={mirror=>void run('preview',{mirror})}/></Field><p className="helper">{t('previewOnly')}</p>
    </FieldGroup>}
    {tab==='audio'&&<FieldGroup>
      <Field><FieldLabel>{t('recordingMode')}</FieldLabel><Options label={t('recordingMode')} value={state.microphone?'microphone':'silent'} disabled={configurationDisabled} onChange={v=>void run('configure',{microphone:v==='microphone'})} items={[["microphone",t('microphone')],["silent",t('silent')]]}/><FieldDescription>{t(!state.microphone?'silentHelp':state.camera?'audioHelp':'audioScreenHelp')}</FieldDescription></Field>
      <Separator/><Field><FieldLabel>{t('device')}</FieldLabel><Choice label={t('device')} value={state.microphoneID||'default'} disabled={configurationDisabled||!state.microphone} onChange={v=>void run('configure',{microphoneID:v==='default'?'':v})} items={deviceItems('microphones',state.microphoneID??'')}/></Field>
      <Field><FieldLabel>{t('inputLevel')}</FieldLabel><meter min={0} max={1} value={state.microphone?(state.level??0):0} aria-label={t('inputLevel')} className="w-full"/></Field>
    </FieldGroup>}
    {tab==='size'&&<FieldGroup>
      <Field><FieldLabel>{t('display')}</FieldLabel><Choice label={t('display')} value={state.displayID??''} disabled={configurationDisabled} onChange={displayID=>void run('configure',{displayID})} items={deviceItems('displays',state.displayID??'')}/></Field>
      <p className="helper">{t('sizeApplied')} · {state.width} × {state.height}</p>
      {[['portrait',0,4],['landscape',4,8],['other',8,12]].map(([name,start,end])=><Field key={name}><FieldLabel>{t(String(name))}</FieldLabel><div className="presets">{presets.slice(Number(start),Number(end)).map(([w,h])=><Button key={`${w}x${h}`} variant={state.width===w&&state.height===h?'default':'outline'} disabled={locked||pending||!desktop} onClick={()=>{setWidth(String(w));setHeight(String(h));setSizeError(false);void run('configure',{width:w,height:h})}}>{w} × {h}</Button>)}</div></Field>)}
      <Separator/><Field data-invalid={sizeError}><FieldLabel>{t('custom')}</FieldLabel><div className="grid grid-cols-2 gap-3"><Field><FieldLabel htmlFor="width">{t('width')}</FieldLabel><Input id="width" type="number" value={width} min={240} max={3840} step={2} aria-invalid={sizeError} disabled={locked} onChange={e=>setWidth(e.target.value)}/></Field><Field><FieldLabel htmlFor="height">{t('height')}</FieldLabel><Input id="height" type="number" value={height} min={240} max={3840} step={2} aria-invalid={sizeError} disabled={locked} onChange={e=>setHeight(e.target.value)}/></Field></div>{sizeError&&<FieldDescription role="alert">{t('invalid_size')}</FieldDescription>}<Button disabled={locked||pending||!desktop} onClick={()=>{const w=Number(width),h=Number(height);setSizeError(!validSize(w,h));if(validSize(w,h))void run('configure',{width:w,height:h})}}>{t('apply')}</Button></Field><p className="helper">{t('capability')}</p>
    </FieldGroup>}
    {tab==='script'&&<FieldGroup>
      <Field><FieldLabel htmlFor="title">{t('scriptTitle')}</FieldLabel><Input id="title" value={title} disabled={locked} onChange={e=>{setTitle(e.target.value);localStorage.setItem('rr.title',e.target.value)}}/></Field>
      <Field><FieldLabel htmlFor="script">{t('body')}</FieldLabel><Textarea id="script" className="min-h-56" value={script} disabled={locked} onChange={e=>{setScript(e.target.value);localStorage.setItem('rr.script',e.target.value)}}/><FieldDescription>{t('chars',{count:[...script.replace(/\r?\n/g,'')].length})}</FieldDescription></Field>
      <Button disabled={locked||pending} onClick={async()=>{if(!desktop||await run('script',{text:script}))await hide()}}>{t('done')}</Button>
    </FieldGroup>}
    {tab==='appearance'&&<FieldGroup>
      <Field><FieldLabel>{t('theme')}</FieldLabel><Options label={t('theme')} value={theme} onChange={v=>{setTheme(v);localStorage.setItem('rr.theme',v);themeApply(v)}} items={['system','light','dark'].map(v=>[v,t(v)])}/></Field>
      <Separator/><Field><FieldLabel>{t('language')}</FieldLabel><Choice label={t('language')} value={i18n.language} onChange={v=>{localStorage.setItem('rr.language',v);void i18n.changeLanguage(v)}} items={[["zh-CN","简体中文"],["en","English"]]}/></Field><p className="helper">{t('autoSaved')}</p>
    </FieldGroup>}
    {tab==='results'&&<FieldGroup>
      {state.result.fatalError&&<Alert variant="destructive"><AlertTitle>{t('interrupted')}</AlertTitle><AlertDescription>{state.result.fatalError}</AlertDescription></Alert>}
      {Object.entries(state.result.saveResults??{}).filter(([,v])=>v!=='not-requested').map(([name,status])=><div className="file-result" key={name}><strong>{t(name==='screen'?'screen':'cameraFile')}</strong><span>{name}{status==='saved'?'.mp4':'.partial.mp4'} · {status==='saved'?t('saved'):status}</span><span className="helper">{(name==='screen'?state.result.outputPixels:state.result.cameraOutputPixels)?.join(' × ')} · {clock((name==='screen'?state.result.screen:state.result.camera)?.lastVideoPTS??0)}</span></div>)}
      <Field><FieldLabel>{t('saveLocation')}</FieldLabel><p className="helper break-all">{state.directory}</p><Button variant="outline" disabled={locked||!desktop} onClick={async()=>{const path=await open({directory:true,multiple:false});if(path)await run('configure',{directory:path})}}>{t('choose')}</Button></Field><Button variant="outline" disabled={!desktop} onClick={()=>void run('open-folder')}><FolderOpen data-icon="inline-start"/>{t('openFolder')}</Button>{recorderButton}
    </FieldGroup>}
    {tab==='quit'&&<FieldGroup><p>{t('quitHelp')}</p><Button variant="outline" onClick={()=>void hide()}>{t('keep')}</Button>{state.phase==='recording'&&<Button onClick={()=>void run('stop')}>{t('stopSave')}</Button>}{state.phase==='countdown'&&<Button onClick={()=>void run('cancel')}>{t('cancel')}</Button>}<Button variant="destructive" disabled={locked||!desktop} onClick={()=>void invoke('quit_app').catch(e=>setError(String(e)))}>{t('exit')}</Button></FieldGroup>}
  </main></TooltipProvider>
}
