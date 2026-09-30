import {useEffect,useRef,useState} from 'react'
import {native} from './lib/native'
import type {Snapshot} from './lib/session'
import {initial} from './lib/session'
type WindowsState=Snapshot&{text?:string;promptReset?:number;theme?:string}
export function WindowsOverlay({frame=false}:{frame?:boolean}){
 const [state,setState]=useState<WindowsState>(initial),[text,setText]=useState(''),[error,setError]=useState('')
 const input=useRef<HTMLTextAreaElement>(null),dirty=useRef(false),reset=useRef(0),revision=useRef(0)
 useEffect(()=>{const poll=async()=>{try{const next=await native('status') as WindowsState;setState(next);if(!dirty.current)setText(next.text??'');if(next.promptReset!==reset.current){reset.current=next.promptReset??0;if(input.current)input.current.scrollTop=0}}catch(e){setError(String(e))}};void poll();const timer=setInterval(()=>void poll(),200);return()=>clearInterval(timer)},[])
 useEffect(()=>{if(!state.playing||!input.current)return;let previous=performance.now();const timer=setInterval(()=>{const now=performance.now();if(input.current)input.current.scrollTop+=(now-previous)/1000*(state.promptSpeed??24);previous=now},16);return()=>clearInterval(timer)},[state.playing,state.promptSpeed])
 if(frame)return <div style={{height:'100vh',border:'2px solid #ef4444',boxSizing:'border-box',background:'transparent'}}><div style={{WebkitAppRegion:'drag',height:24,background:'#ef4444',color:'white',fontSize:12,textAlign:'center'} as React.CSSProperties}>RecordReady · {state.width} × {state.height}</div></div>
 return <div style={{height:'100vh',display:'flex',flexDirection:'column',background:state.theme==='dark'?`rgba(24,24,27,${state.promptOpacity??1})`:`rgba(255,255,255,${state.promptOpacity??1})`,color:state.theme==='dark'?'#fafafa':'#18181b',border:'1px solid #888',borderRadius:8,overflow:'hidden'}}>
  <div style={{WebkitAppRegion:'drag',height:20,flexShrink:0,textAlign:'center',fontSize:12,opacity:.6} as React.CSSProperties}>⋯</div>
  <textarea ref={input} aria-label="口播稿 / Script" placeholder="输入口播稿… / Enter your script…" value={text} onFocus={()=>{if(state.playing)void native('prompt',{playing:false})}} onChange={e=>{const value=e.target.value;setText(value);dirty.current=true;const current=++revision.current;void native('prompt',{text:value}).then(()=>{if(current===revision.current)dirty.current=false}).catch(e=>setError(String(e)))}} style={{flex:1,width:'100%',resize:'none',border:0,outline:0,padding:16,background:'transparent',color:'inherit',fontSize:state.fontSize??32,lineHeight:1.65}}/>
  {error&&<p role="alert">{error}</p>}
 </div>
}
