import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './index.css'
import { customCoverService } from './services/customCoverService'
import { generatedCoverService } from './services/generatedCoverService'

declare global {
  interface Window {
    customCoverService?: typeof customCoverService
    generatedCoverService?: typeof generatedCoverService
  }
}

if (import.meta.env.DEV) {
  window.customCoverService = customCoverService
  window.generatedCoverService = generatedCoverService
}

// Prevenir menú contextual por defecto (excepto para inputs y menús personalizados)
document.addEventListener('contextmenu', (e) => {
  const target = e.target as HTMLElement
  
  // Permitir menú contextual en inputs y textareas
  if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
    return
  }
  
  // Permitir menú contextual en elementos editables
  if (target.contentEditable === 'true') {
    return
  }
  
  // Permitir menú contextual personalizado (tiene data-song-id u otros atributos)
  if (target.closest('[data-song-id]') || target.closest('[role="menuitem"]')) {
    // El menú contextual personalizado manejará esto
    return
  }
  
  // Prevenir menú contextual por defecto en todo lo demás
  e.preventDefault()
})

// Prevenir comportamiento de arrastrar imágenes
document.addEventListener('dragstart', (e) => {
  if ((e.target as HTMLElement).tagName === 'IMG') {
    e.preventDefault()
  }
})

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)

