import { useEffect, useState } from 'react'
import { invoke } from '@tauri-apps/api/core'
import { Button } from './ui/button'
import { desktop } from '../lib/native'
import { downloadProgress, type UpdateState } from '../lib/updates'

export function UpdateSettings({zh,locked,compact=false}:{zh:boolean;locked:boolean;compact?:boolean}) {
  const [state,setState]=useState<UpdateState>({phase:'unavailable',version:'development'})
  const [error,setError]=useState('')
  const [pending,setPending]=useState(false)
  useEffect(()=>{
    if(!desktop)return
    let disposed=false,fetching=false
    const poll=async()=>{
      if(fetching)return
      fetching=true
      try { const value=await invoke<UpdateState>('native_request',{request:{action:'update',operation:'status'}});if(!disposed)setState(value) }
      catch(e){if(!disposed)setError(String(e))}finally{fetching=false}
    }
    void poll();const timer=setInterval(()=>void poll(),500)
    return()=>{disposed=true;clearInterval(timer)}
  },[])
  async function act(operation:string) {
    setPending(true);setError('')
    try{setState(await invoke<UpdateState>('native_request',{request:{action:'update',operation}}))}
    catch(e){setError(String(e))}finally{setPending(false)}
  }
  const labels:Record<string,string> = zh ? {
    unavailable:'开发构建未启用更新',idle:'检查可用更新',checking:'正在检查更新…',current:'已完成检查',available:'发现新版本',
    downloading:'正在下载…',preparing:'正在验证并准备安装…',ready:'更新已就绪',installing:'正在重启安装…',error:'更新失败，可重新检查',
  } : {unavailable:'Updates unavailable in this development build',idle:'Check for updates',checking:'Checking…',current:'Check complete',available:'Update available',downloading:'Downloading…',preparing:'Verifying and preparing…',ready:'Ready to install',installing:'Restarting to install…',error:'Update failed; check again'}
  const busy=['checking','downloading','preparing','installing'].includes(state.phase)
  return <section aria-label={zh?'软件更新':'Software updates'} style={{display:'grid',gap:10}}>
    <p className="helper">RecordReady {state.version}{!compact&&state.build?` (${state.build})`:''}</p>
    <p role="status" className="helper">{labels[state.phase]??state.phase}{['available','ready'].includes(state.phase)?` · ${state.availableVersion}`:''}</p>
    {state.phase==='downloading'&&<p className="helper">{downloadProgress(state.received??0,state.total??0)}</p>}
    {state.phase==='available'?<Button disabled={pending} onClick={()=>void act('download')}>{zh?'下载更新':'Download update'}</Button>:
      state.phase==='ready'?<><Button disabled={locked||pending} onClick={()=>void act('install')}>{zh?'重启安装':'Restart and install'}</Button>{!compact&&<Button variant="outline" onClick={()=>void act('later')}>{zh?'稍后':'Later'}</Button>}</>:
      <Button variant="outline" disabled={!desktop||pending||busy||state.phase==='unavailable'} onClick={()=>void act('check')}>{zh?'检查更新…':'Check for updates…'}</Button>}
    {['checking','downloading'].includes(state.phase)&&<Button variant="ghost" disabled={pending} onClick={()=>void act('cancel')}>{zh?'取消':'Cancel'}</Button>}
    {state.phase==='ready'&&locked&&<p className="helper">{zh?'请在录制及保存完成后安装。':'Finish recording and saving before installing.'}</p>}
    {(error||state.message)&&<p role={error||state.phase==='error'?'alert':undefined} className="helper" style={{overflowWrap:'anywhere'}}>{error==='session_busy'?(zh?'当前会话忙碌，请稍后重试。':'The session is busy. Please try later.'):error||state.message}</p>}
  </section>
}
