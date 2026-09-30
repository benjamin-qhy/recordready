import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import {WindowsOverlay} from './WindowsOverlay'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {['frame','prompt-text'].includes(new URLSearchParams(location.search).get('view')??'') ? <WindowsOverlay frame={new URLSearchParams(location.search).get('view')==='frame'}/> : <App />}
  </StrictMode>,
)
