import {useEffect,useRef,useState} from 'react'
import {ExternalLink,Info} from 'lucide-react'
import {Button} from './ui/button'
import {Switch} from './ui/switch'
import {native} from '@/lib/native'
export type BeautyValues={enabled:boolean;smoothing:number;slim:number;front:number;left:number;right:number}
const defaults:BeautyValues={enabled:false,smoothing:0,slim:0,front:0,left:0,right:0}
export function BeautySettings({initial,available,zh}:{initial?:BeautyValues;available:boolean;zh:boolean}) {
 const [values,setValues]=useState(initial??defaults)
 const [error,setError]=useState('')
 const queue=useRef(Promise.resolve())
 const send=(action:string,args:Record<string,unknown>)=>{queue.current=queue.current.then(async()=>{await native(action,args)}).catch(e=>setError(String(e)))}
 const change=(patch:Partial<BeautyValues>)=>{setValues(v=>({...v,...patch}));send('beauty',patch)}
 const compare=(active:boolean)=>send('beauty-compare',{active})
 useEffect(()=>{const release=()=>{queue.current=queue.current.then(async()=>{await native('beauty-compare',{active:false})}).catch(()=>{})};window.addEventListener('blur',release);return()=>{window.removeEventListener('blur',release);release()}},[])
 const row=(key:Exclude<keyof BeautyValues,'enabled'>,label:string)=><label className="beauty-slider" key={key}><span>{label}</span><input aria-label={label} type="range" min="0" max="100" step="1" value={values[key]} disabled={!values.enabled} onChange={e=>change({[key]:Number(e.target.value)})}/><output>{values[key]}%</output></label>
 return <div className="beauty-settings">
 <div className="beauty-enable"><label htmlFor="beauty-enabled">{zh?'启用美颜与补光':'Enable beauty & lighting'}</label><Switch id="beauty-enabled" checked={values.enabled} onCheckedChange={enabled=>change({enabled})}/></div>
 <h2>{zh?'美颜':'Beauty'}</h2><div className="beauty-group">{row('smoothing',zh?'磨皮':'Smoothing')}{row('slim',zh?'瘦脸':'Face slimming')}</div>
 <h2>{zh?'补光':'Lighting'}</h2><div className="beauty-group">{row('front',zh?'正面柔光':'Front fill')}{row('left',zh?'画面左前柔光':'Frame-left fill')}{row('right',zh?'画面右前柔光':'Frame-right fill')}</div>
 <div className="beauty-actions"><Button disabled={!values.enabled} onPointerDown={e=>{e.currentTarget.setPointerCapture(e.pointerId);compare(true)}} onPointerUp={()=>compare(false)} onPointerCancel={()=>compare(false)} onLostPointerCapture={()=>compare(false)} onKeyDown={e=>{if((e.key===' '||e.key==='Enter')&&!e.repeat){e.preventDefault();compare(true)}}} onKeyUp={e=>{if(e.key===' '||e.key==='Enter'){e.preventDefault();compare(false)}}} onBlur={()=>compare(false)}>{zh?'按住对比':'Hold to compare'}</Button><Button variant="secondary" onClick={()=>change(defaults)}>{zh?'恢复默认':'Reset'}</Button></div>
 <p className="helper"><Info size={14}/>{zh?'对比仅暂停预览中的通用效果；设置自动保存。':'Compare only bypasses preview beauty. Settings save automatically.'}</p>{error&&<p role="alert">{error}</p>}
 {available&&<div className="beauty-system-section"><Button variant="outline" className="beauty-system" onClick={()=>send('system-camera-effects',{})}>{zh?'macOS 摄像头效果…':'macOS Camera Effects…'}<ExternalLink/></Button><p className="helper">{zh?'打开系统取景、灯光与背景设置。':'Open system framing, lighting and background settings.'}</p></div>}
 </div>
}
