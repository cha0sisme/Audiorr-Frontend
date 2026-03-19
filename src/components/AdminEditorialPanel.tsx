import { useEffect, useState } from 'react'
import { navidromeApi, Playlist } from '../services/navidromeApi'
import { backendApi } from '../services/backendApi'
import {
  SparklesIcon,
  PlusIcon,
  XMarkIcon,
  ArrowsUpDownIcon,
  CheckCircleIcon,
} from '@heroicons/react/24/outline'
import Spinner from './Spinner'

export interface PlaylistSection {
  id: string
  title: string
  type: 'fixed_daily' | 'fixed_user' | 'fixed_smart' | 'dynamic'
  playlists?: string[]
}

const DEFAULT_LAYOUT: PlaylistSection[] = [
  { id: 'daily-mixes', title: 'Tus mixes diarios', type: 'fixed_daily' },
  { id: 'smart-playlists', title: 'Hecho especialmente para ti', type: 'fixed_smart' },
  { id: 'my-playlists', title: 'Mis playlists', type: 'fixed_user' },
]

export default function AdminEditorialPanel() {
  const [playlists, setPlaylists] = useState<Playlist[]>([])
  const [sections, setSections] = useState<PlaylistSection[]>([])
  const [thisIsMapping, setThisIsMapping] = useState<Record<string, string>>({})
  const [isLoading, setIsLoading] = useState(true)
  const [isSaving, setIsSaving] = useState(false)
  const [saveSuccess, setSaveSuccess] = useState(false)

  // Load playlists and settings
  const loadData = async () => {
    setIsLoading(true)
    try {
      const [fetchedPlaylists, savedLayout, thisIs] = await Promise.all([
        navidromeApi.getPlaylists(),
        backendApi.getGlobalSetting<PlaylistSection[]>('homepage_layout'),
        backendApi.getGlobalSetting<Record<string, string>>('this_is_playlists'),
      ])
      setPlaylists(fetchedPlaylists)
      setSections(savedLayout && savedLayout.length > 0 ? savedLayout : DEFAULT_LAYOUT)
      setThisIsMapping(thisIs ?? {})
    } catch (error) {
      console.error('[AdminEditorial] Error loading data', error)
    } finally {
      setIsLoading(false)
    }
  }

  useEffect(() => {
    loadData()
  }, [])

  const handleToggleEditorial = async (playlist: Playlist) => {
    const isEditorial = playlist.comment && playlist.comment.includes('[Editorial]')
    
    // Preparar nuevo comentario
    let newComment = playlist.comment || ''
    if (isEditorial) {
      newComment = newComment.replace('[Editorial]', '').trim()
    } else {
      newComment = newComment ? `${newComment}\n[Editorial]` : '[Editorial]'
    }

    try {
      // Usar navidromeApi para actualizar (se asume que hay un endpoint u updatePlaylist)
      // Como navidromeApi.updatePlaylist no permite actualizar comentarios directamente fácilmente si no está implementado
      // vamos a asumir que navidromeApi.updatePlaylist soporta { comment: string }
      await navidromeApi.updatePlaylist(playlist.id, { comment: newComment })
      
      // Update local state
      setPlaylists(prev => prev.map(p => {
        if (p.id === playlist.id) {
          return { ...p, comment: newComment }
        }
        return p
      }))
    } catch (error) {
      alert('Error cambiando estado editorial: ' + (error as Error).message)
    }
  }

  const handleChangeCoverType = async (playlist: Playlist, coverType: string) => {
    let newComment = playlist.comment || ''
    newComment = newComment.replace(/\[Cover:[a-zA-Z-]+\]/gi, '').trim()
    
    if (coverType !== 'default') {
      newComment = newComment ? `${newComment}\n[Cover:${coverType}]` : `[Cover:${coverType}]`
    }

    try {
      await navidromeApi.updatePlaylist(playlist.id, { comment: newComment })
      setPlaylists(prev => prev.map(p => p.id === playlist.id ? { ...p, comment: newComment } : p))
    } catch (error) {
      alert('Error cambiando portada: ' + (error as Error).message)
    }
  }

  const handleSaveLayout = async () => {
    setIsSaving(true)
    setSaveSuccess(false)
    try {
      await backendApi.setGlobalSetting('homepage_layout', sections)
      setSaveSuccess(true)
      setTimeout(() => setSaveSuccess(false), 3000)
    } catch (error) {
      alert('Error guardando layout: ' + (error as Error).message)
    } finally {
      setIsSaving(false)
    }
  }

  const addSection = () => {
    const newSection: PlaylistSection = {
      id: `sec-${Date.now()}`,
      title: 'Nueva Sección',
      type: 'dynamic',
      playlists: []
    }
    setSections([...sections, newSection])
  }

  const removeSection = (id: string) => {
    setSections(sections.filter(s => s.id !== id))
  }

  const moveUp = (index: number) => {
    if (index === 0) return
    const newSecs = [...sections]
    const temp = newSecs[index]
    newSecs[index] = newSecs[index - 1]
    newSecs[index - 1] = temp
    setSections(newSecs)
  }

  const moveDown = (index: number) => {
    if (index === sections.length - 1) return
    const newSecs = [...sections]
    const temp = newSecs[index]
    newSecs[index] = newSecs[index + 1]
    newSecs[index + 1] = temp
    setSections(newSecs)
  }

  const updateSectionTitle = (id: string, title: string) => {
    setSections(sections.map(s => s.id === id ? { ...s, title } : s))
  }

  const togglePlaylistInSection = (sectionId: string, playlistId: string) => {
    setSections(sections.map(s => {
      if (s.id !== sectionId) return s
      const pl = s.playlists || []
      if (pl.includes(playlistId)) {
        return { ...s, playlists: pl.filter(id => id !== playlistId) }
      } else {
        return { ...s, playlists: [...pl, playlistId] }
      }
    }))
  }

  if (isLoading) {
    return (
      <div className="flex justify-center items-center py-20">
        <Spinner size="lg" />
      </div>
    )
  }

  const filteredPlaylists = playlists.filter(p => {
    const name = p.name || '';
    const comment = p.comment || '';
    if (name.toLowerCase().includes('mix diario') || comment.includes('Mix Diario')) return false;
    if (comment.includes('Smart Playlist')) return false;
    return true;
  })

  const editorialPlaylists = playlists.filter(p => p.comment && p.comment.includes('[Editorial]'))

  return (
    <div className="space-y-10 max-w-5xl mx-auto">
      
      {/* 1. Header & Lista de Playlists */}
      <section>
        <div className="mb-5">
          <div className="flex items-center gap-2.5 mb-1">
            <SparklesIcon className="w-5 h-5 text-gray-400" />
            <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Curaduría</h2>
          </div>
          <p className="text-sm text-gray-500 dark:text-gray-400 leading-relaxed">
            Marca playlists como destacadas (Editorial) y elige su diseño de portada.
          </p>
        </div>

        <div className="bg-white dark:bg-gray-900 rounded-2xl border border-gray-200 dark:border-gray-800 p-2 md:p-4 shadow-sm max-h-[500px] overflow-y-auto w-full">
          <ul className="divide-y divide-gray-200/50 dark:divide-gray-800/50 w-full overflow-hidden">
            {filteredPlaylists.map(pl => {
              const isEd = pl.comment && pl.comment.includes('[Editorial]')
              const isSpotify = pl.name.startsWith('[Spotify] ') || pl.comment?.includes('Spotify Synced')
              const coverMatch = pl.comment?.match(/\[Cover:([a-zA-Z-]+)\]/i)
              const currentCover = coverMatch ? coverMatch[1].toLowerCase() : 'default'
              const thisIsArtist = thisIsMapping[pl.id]

              return (
                <li key={pl.id} className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 py-4 px-2 sm:px-4 hover:bg-white/60 dark:hover:bg-gray-800/40 rounded-2xl transition-all">
                  <div className="flex-1 min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="text-base font-bold text-gray-900 dark:text-white truncate">
                        {pl.name}
                      </p>
                      {isSpotify && (
                        <span className="shrink-0 bg-green-500/10 text-green-600 dark:text-green-500 text-[10px] font-bold px-2 py-0.5 rounded-full uppercase tracking-widest">
                          Spotify
                        </span>
                      )}
                      {thisIsArtist && (
                        <span className="shrink-0 bg-indigo-500/10 text-indigo-600 dark:text-indigo-400 text-[10px] font-bold px-2 py-0.5 rounded-full uppercase tracking-widest">
                          This Is · {thisIsArtist}
                        </span>
                      )}
                    </div>
                    <p className="text-sm text-gray-400 mt-0.5 truncate">De {pl.owner}</p>
                  </div>

                  <div className="flex items-center gap-4 sm:gap-6 justify-between sm:justify-end border-t border-gray-200 dark:border-gray-800 sm:border-transparent pt-3 sm:pt-0">
                    {(isEd || isSpotify) && (
                      <div className="flex flex-col gap-1 items-start sm:items-end">
                        <label className="text-[10px] uppercase font-bold text-gray-400 tracking-wider">Diseño</label>
                        {thisIsArtist ? (
                          <span
                            title="Controlado desde Playlists de Audiorr → This Is"
                            className="text-xs font-semibold text-indigo-500 dark:text-indigo-400 px-3 py-1.5 bg-indigo-50 dark:bg-indigo-500/10 rounded-xl cursor-default"
                          >
                            This Is (prioritario)
                          </span>
                        ) : (
                          <select
                            value={currentCover}
                            onChange={(e) => handleChangeCoverType(pl, e.target.value)}
                            className="bg-gray-100 dark:bg-gray-800 border-none text-sm font-semibold text-gray-700 dark:text-gray-200 rounded-xl px-3 py-1.5 focus:ring-2 focus:ring-indigo-600 cursor-pointer appearance-none shrink-0"
                          >
                            <option value="default">Automático</option>
                            <option value="classic">Clásica</option>
                            <option value="headline">Headline</option>
                            <option value="graphic">Gráfica</option>
                            <option value="artist-gradient">Gradiente</option>
                          </select>
                        )}
                      </div>
                    )}
                    
                    <div className="flex flex-col gap-1 items-end">
                       <label className="text-[10px] uppercase font-bold text-gray-400 tracking-wider">Destacar</label>
                       <button
                         onClick={() => handleToggleEditorial(pl)}
                         className={`relative inline-flex h-7 w-12 shrink-0 items-center rounded-full transition-colors duration-300 ease-in-out focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-600 focus-visible:ring-opacity-75 ${
                           isEd ? 'bg-indigo-600' : 'bg-gray-300 dark:bg-gray-700'
                         }`}
                       >
                         <span
                           className={`inline-block h-5 w-5 transform rounded-full bg-white shadow-md transition-transform duration-300 ease-in-out ${
                             isEd ? 'translate-x-6' : 'translate-x-1'
                           }`}
                         />
                       </button>
                    </div>
                  </div>
                </li>
              )
            })}
          </ul>
        </div>
      </section>

      {/* 2. Section Builder */}
      <section>
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 mb-5">
          <div>
            <div className="flex items-center gap-2.5 mb-1">
              <ArrowsUpDownIcon className="w-5 h-5 text-gray-400" />
              <h2 className="text-lg font-semibold text-gray-900 dark:text-white">Estructura</h2>
            </div>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Define el orden de las filas en la pantalla de inicio.
            </p>
          </div>
          <div className="flex items-center gap-2">
            {!sections.some(s => s.type === 'fixed_smart') && (
              <button
                onClick={() => setSections([...sections, { id: 'smart-playlists', title: 'Hecho especialmente para ti', type: 'fixed_smart' }])}
                className="flex items-center justify-center gap-2 px-4 py-2 bg-purple-600 hover:bg-purple-500 active:scale-95 text-white text-sm font-semibold rounded-xl transition-all shrink-0"
              >
                <SparklesIcon className="w-4 h-4" /> Smart Playlists
              </button>
            )}
            <button
              onClick={addSection}
              className="flex items-center justify-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-500 active:scale-95 text-white text-sm font-semibold rounded-xl transition-all shrink-0"
            >
              <PlusIcon className="w-4 h-4" /> Nueva fila
            </button>
          </div>
        </div>

        <div className="space-y-4">
          {sections.map((sec, index) => (
            <div key={sec.id} className="bg-white dark:bg-gray-900 rounded-2xl p-4 sm:p-6 border border-gray-200 dark:border-gray-800 shadow-sm flex flex-col gap-5 group transition-all">
              
              <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b border-gray-100 dark:border-gray-700/50 pb-4 sm:border-0 sm:pb-0">
                <div className="flex items-center gap-3 sm:gap-5 flex-1 w-full">
                  <div className="flex flex-col sm:flex-row gap-1 sm:gap-2">
                    <button onClick={() => moveUp(index)} disabled={index === 0} className="p-1 sm:p-2 bg-gray-100 dark:bg-gray-700 rounded-lg text-gray-500 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white disabled:opacity-30 transition-colors">
                      <span className="sm:hidden block text-xs">↑</span>
                      <ArrowsUpDownIcon className="w-4 h-4 hidden sm:block rotate-180" />
                    </button>
                    <button onClick={() => moveDown(index)} disabled={index === sections.length - 1} className="p-1 sm:p-2 bg-gray-100 dark:bg-gray-700 rounded-lg text-gray-500 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white disabled:opacity-30 transition-colors">
                       <span className="sm:hidden block text-xs">↓</span>
                      <ArrowsUpDownIcon className="w-4 h-4 hidden sm:block" />
                    </button>
                  </div>
                  
                  <div className="flex-1 w-full min-w-0">
                    {sec.type === 'dynamic' ? (
                      <input
                        type="text"
                        className="w-full text-base font-semibold bg-transparent border-b-2 border-transparent hover:border-gray-300 dark:hover:border-gray-600 focus:border-indigo-500 focus:outline-none px-1 py-1 truncate"
                        value={sec.title}
                        placeholder="Título de la fila..."
                        onChange={(e) => updateSectionTitle(sec.id, e.target.value)}
                      />
                    ) : (
                      <div className="flex items-center gap-2 sm:gap-3 flex-wrap">
                        <h3 className="text-base font-semibold text-gray-900 dark:text-white truncate">
                          {sec.title}
                        </h3>
                        <span className="text-[10px] uppercase font-bold tracking-widest px-2.5 py-1 rounded-full bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-400 shrink-0">
                          Automático
                        </span>
                      </div>
                    )}
                  </div>
                </div>

                {(sec.type === 'dynamic' || sec.type === 'fixed_smart') && (
                  <button onClick={() => removeSection(sec.id)} className="shrink-0 self-end sm:self-auto p-2 sm:p-3 text-red-500 bg-red-50 dark:bg-red-500/10 hover:bg-red-100 dark:hover:bg-red-500/20 rounded-xl transition-colors sm:opacity-0 sm:group-hover:opacity-100">
                    <XMarkIcon className="w-5 h-5" />
                  </button>
                )}
              </div>

              {sec.type === 'fixed_smart' && (
                <div className="mt-2 sm:ml-[72px]">
                  <p className="text-[11px] text-gray-400 uppercase font-bold mb-2 tracking-widest">Contenido</p>
                  <p className="text-sm text-gray-500 dark:text-gray-400 bg-purple-50 dark:bg-purple-500/10 px-4 py-2.5 rounded-xl border border-purple-100 dark:border-purple-500/20">
                    Muestra automáticamente <span className="font-semibold text-purple-700 dark:text-purple-400">En Bucle</span> y <span className="font-semibold text-purple-700 dark:text-purple-400">Tiempo Atrás</span> de cada usuario. El estilo de portada se configura en la pestaña <em>Auto-Playlists</em>.
                  </p>
                </div>
              )}

              {sec.type === 'dynamic' && (
                <div className="mt-2 sm:ml-[72px]">
                  <p className="text-[11px] text-gray-400 uppercase font-bold mb-3 tracking-widest">Contenido (Playlists Editoriales)</p>
                  <div className="flex flex-wrap gap-2">
                    {editorialPlaylists.map(pl => {
                      const isActive = (sec.playlists || []).includes(pl.id)
                      return (
                        <button
                          key={pl.id}
                          onClick={() => togglePlaylistInSection(sec.id, pl.id)}
                          className={`text-xs sm:text-sm font-medium px-4 py-2 rounded-2xl transition-all duration-200 border-2 ${
                            isActive 
                            ? 'bg-indigo-600 border-indigo-600 text-white shadow-md shadow-indigo-500/30 scale-105' 
                            : 'bg-transparent border-gray-200 dark:border-gray-700 text-gray-600 dark:text-gray-300 hover:border-gray-300 dark:hover:border-gray-600 active:scale-95'
                          }`}
                        >
                          {pl.name}
                        </button>
                      )
                    })}
                    {editorialPlaylists.length === 0 && (
                      <span className="text-sm text-gray-400 italic bg-gray-50 dark:bg-gray-800/50 px-4 py-2 rounded-xl border border-dashed border-gray-200 dark:border-gray-700">
                         Marca alguna playlist como Editorial arriba primero.
                      </span>
                    )}
                  </div>
                </div>
              )}

            </div>
          ))}
        </div>

        <div className="mt-10 flex flex-col sm:flex-row justify-end items-center gap-4">
          {saveSuccess && (
            <span className="text-emerald-500 text-sm font-bold flex items-center gap-2">
              <CheckCircleIcon className="w-5 h-5" /> Publicado
            </span>
          )}
          <button
            onClick={handleSaveLayout}
            disabled={isSaving}
            className="w-full sm:w-auto bg-indigo-600 hover:bg-indigo-500 text-white px-8 py-3 rounded-xl font-semibold active:scale-95 transition-all flex items-center justify-center gap-2 shadow-sm shadow-indigo-500/20"
          >
            {isSaving ? <Spinner size="sm" /> : 'Guardar y Publicar'}
          </button>
        </div>
      </section>
    </div>
  )
}
