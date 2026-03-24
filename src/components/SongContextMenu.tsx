import { useState, useEffect, useRef, useCallback } from 'react'
import { createPortal } from 'react-dom'
import { useNavigate } from 'react-router-dom'
import { motion, AnimatePresence } from 'framer-motion'
import { Capacitor } from '@capacitor/core'
import { Song, navidromeApi, Playlist, isSmartPlaylist, isEditorialPlaylist } from '../services/navidromeApi'
import { usePlayerActions } from '../contexts/PlayerContext'
import UpdatePlayCountModal from './UpdatePlayCountModal'
import SmartTagModal from './SmartTagModal'
import AlbumCover from './AlbumCover'
import CreatePlaylistModal from './CreatePlaylistModal'
import {
  QueueListIcon,
  UserIcon,
  MusicalNoteIcon,
  PlusCircleIcon,
  ChevronRightIcon,
  CheckIcon,
  HashtagIcon,
  TagIcon,
} from '@heroicons/react/24/solid'

const VinylIcon = ({ className }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="currentColor" xmlns="http://www.w3.org/2000/svg">
    <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 14c-2.21 0-4-1.79-4-4s1.79-4 4-4 4 1.79 4 4-1.79 4-4 4zm0-6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z" fillRule="evenodd" clipRule="evenodd" />
  </svg>
)

interface Props {
  x: number
  y: number
  song: Song
  onClose: () => void
  onBeforeNavigate?: () => void
  showGoToArtist?: boolean
  showGoToAlbum?: boolean
  showGoToSong?: boolean
  isAdmin?: boolean
}

export default function SongContextMenu({
  x,
  y,
  song,
  onClose,
  onBeforeNavigate,
  showGoToArtist = true,
  showGoToAlbum = true,
  showGoToSong = true,
  isAdmin = false,
}: Props) {
  const navigate = useNavigate()
  const playerActions = usePlayerActions()
  const [playlists, setPlaylists] = useState<Playlist[]>([])
  const [loadingPlaylists, setLoadingPlaylists] = useState(false)
  const [showPlaylistSubmenu, setShowPlaylistSubmenu] = useState(false)
  const [addingToPlaylist, setAddingToPlaylist] = useState<string | null>(null)
  const [showUpdatePlayCountModal, setShowUpdatePlayCountModal] = useState(false)
  const [showSmartTagModal, setShowSmartTagModal] = useState(false)
  const [showCreatePlaylistModal, setShowCreatePlaylistModal] = useState(false)
  const [isMobile] = useState(() => window.innerWidth < 768)
  const [closing, setClosing] = useState(false)
  const sheetRef = useRef<HTMLDivElement>(null)

  const handleClose = useCallback(() => {
    if (!isMobile) { onClose(); return }
    setClosing(true)
    // Wait for the CSS exit animation to finish before unmounting
    const sheet = sheetRef.current
    if (sheet) {
      const onEnd = () => { sheet.removeEventListener('animationend', onEnd); onClose() }
      sheet.addEventListener('animationend', onEnd)
    } else {
      onClose()
    }
  }, [isMobile, onClose])

  useEffect(() => {
    const fetchPlaylists = async () => {
      setLoadingPlaylists(true)
      try {
        const allPlaylists = await navidromeApi.getPlaylists()
        const currentUser = navidromeApi.getUsername()
        const userPlaylists = allPlaylists.filter(
          p => !isSmartPlaylist(p) && !isEditorialPlaylist(p) && (!currentUser || p.owner === currentUser)
        )
        setPlaylists(userPlaylists)
      } catch (error) {
        console.error('[SongContextMenu] Error al cargar playlists:', error)
      } finally {
        setLoadingPlaylists(false)
      }
    }
    fetchPlaylists()
  }, [])

  const handleAddToQueue = () => {
    playerActions.addToQueue(song)
    onClose()
  }

  const handleGoToArtist = (e: React.MouseEvent) => {
    e.stopPropagation()
    onBeforeNavigate?.()
    navigate(`/artists/${encodeURIComponent(song.artist)}`)
    onClose()
  }

  const handleGoToAlbum = (e: React.MouseEvent) => {
    e.stopPropagation()
    onBeforeNavigate?.()
    if (song.albumId) navigate(`/albums/${song.albumId}`)
    onClose()
  }

  const handleGoToSong = (e: React.MouseEvent) => {
    e.stopPropagation()
    onBeforeNavigate?.()
    navigate(`/songs/${song.id}`)
    onClose()
  }

  const handleCreateAndAddToPlaylist = async (name: string, description?: string) => {
    const playlistId = await navidromeApi.createPlaylist(name)
    if (!playlistId) throw new Error('No se pudo crear la playlist')
    if (description) {
      await navidromeApi.updatePlaylist(playlistId, { comment: description })
    }
    await navidromeApi.addSongToPlaylist(playlistId, song.id)
    setTimeout(() => onClose(), 300)
  }

  const handleAddToPlaylist = async (playlistId: string) => {
    setAddingToPlaylist(playlistId)
    try {
      const success = await navidromeApi.addSongToPlaylist(playlistId, song.id)
      if (success) {
        setTimeout(() => { onClose() }, 500)
      } else {
        setAddingToPlaylist(null)
      }
    } catch {
      setAddingToPlaylist(null)
    }
  }

  // ── Mobile: iOS action sheet (CSS-animated for 120 Hz perf) ─────────────────
  if (isMobile) {
    return createPortal(
      <>
        <div
          className={`fixed inset-0 z-[9998] bg-black/50 ctx-backdrop${closing ? ' closing' : ''}`}
          onClick={handleClose}
        />
        <div
          ref={sheetRef}
          className={`fixed bottom-0 left-0 right-0 z-[9999] ctx-sheet${closing ? ' closing' : ''}`}
          style={{
            // On native iOS, the TabBar (~49px) and NowPlayingBar (~64px) are UIKit views
            // rendered OUTSIDE the WebView — they overlay the bottom. Add extra padding
            // so the cancel button is visible above them.
            paddingBottom: Capacitor.isNativePlatform()
              ? 'calc(env(safe-area-inset-bottom) + 130px)'
              : 'env(safe-area-inset-bottom)',
          }}
        >
          {/* Song info header */}
          <div className="mx-3 mb-2 bg-[#2c2c2e] rounded-2xl overflow-hidden">
            <div className="flex items-center gap-3 px-4 py-3.5 border-b border-white/[0.08]">
              <div className="w-10 h-10 rounded-lg overflow-hidden flex-shrink-0">
                <AlbumCover coverArtId={song.coverArt} size={80} className="w-full h-full" />
              </div>
              <div className="flex-1 min-w-0">
                <p className="text-white text-sm font-semibold truncate">{song.title}</p>
                <p className="text-white/50 text-xs truncate">{song.artist}</p>
              </div>
            </div>

            {!showPlaylistSubmenu ? (
              <>
                <button className="w-full flex items-center gap-4 px-4 py-3.5 border-b border-white/[0.06] hover:bg-white/5 active:bg-white/10 transition-colors text-left" onClick={handleAddToQueue}>
                  <QueueListIcon className="w-5 h-5 text-white/70 flex-shrink-0" />
                  <span className="text-white text-[15px]">Añadir a la cola</span>
                </button>

                <button className="w-full flex items-center justify-between gap-4 px-4 py-3.5 border-b border-white/[0.06] hover:bg-white/5 active:bg-white/10 transition-colors text-left" onClick={() => setShowPlaylistSubmenu(true)}>
                  <div className="flex items-center gap-4">
                    <PlusCircleIcon className="w-5 h-5 text-white/70 flex-shrink-0" />
                    <span className="text-white text-[15px]">Añadir a playlist</span>
                  </div>
                  <ChevronRightIcon className="w-4 h-4 text-white/30" />
                </button>

                {showGoToArtist && (
                  <button className="w-full flex items-center gap-4 px-4 py-3.5 border-b border-white/[0.06] hover:bg-white/5 active:bg-white/10 transition-colors text-left" onClick={handleGoToArtist}>
                    <UserIcon className="w-5 h-5 text-white/70 flex-shrink-0" />
                    <span className="text-white text-[15px]">Ir al artista</span>
                  </button>
                )}
                {showGoToAlbum && song.albumId && (
                  <button className="w-full flex items-center gap-4 px-4 py-3.5 border-b border-white/[0.06] hover:bg-white/5 active:bg-white/10 transition-colors text-left" onClick={handleGoToAlbum}>
                    <VinylIcon className="w-5 h-5 text-white/70 flex-shrink-0" />
                    <span className="text-white text-[15px]">Ir al álbum</span>
                  </button>
                )}
                {showGoToSong && (
                  <button className="w-full flex items-center gap-4 px-4 py-3.5 hover:bg-white/5 active:bg-white/10 transition-colors text-left" onClick={handleGoToSong}>
                    <MusicalNoteIcon className="w-5 h-5 text-white/70 flex-shrink-0" />
                    <span className="text-white text-[15px]">Ir a la canción</span>
                  </button>
                )}
                {isAdmin && (
                  <>
                    <button className="w-full flex items-center gap-4 px-4 py-3.5 border-t border-white/[0.06] hover:bg-white/5 active:bg-white/10 transition-colors text-left" onClick={(e) => { e.stopPropagation(); setShowUpdatePlayCountModal(true) }}>
                      <HashtagIcon className="w-5 h-5 text-white/70 flex-shrink-0" />
                      <span className="text-white text-[15px]">Actualizar reproducciones</span>
                    </button>
                    <button className="w-full flex items-center gap-4 px-4 py-3.5 hover:bg-white/5 active:bg-white/10 transition-colors text-left" onClick={(e) => { e.stopPropagation(); setShowSmartTagModal(true) }}>
                      <TagIcon className="w-5 h-5 text-white/70 flex-shrink-0" />
                      <span className="text-white text-[15px]">Editar etiquetas</span>
                    </button>
                  </>
                )}
              </>
            ) : (
              <>
                <button className="flex items-center gap-2 px-4 py-3 border-b border-white/[0.06] text-white/60 hover:text-white transition-colors text-sm w-full text-left" onClick={() => setShowPlaylistSubmenu(false)}>
                  <ChevronRightIcon className="w-4 h-4 rotate-180" />
                  Atrás
                </button>
                <button className="w-full flex items-center gap-3 px-4 py-3.5 border-b border-white/[0.06] hover:bg-white/5 active:bg-white/10 transition-colors text-left" onClick={() => setShowCreatePlaylistModal(true)}>
                  <PlusCircleIcon className="w-5 h-5 text-[#0a84ff] flex-shrink-0" />
                  <span className="text-[#0a84ff] text-[15px]">Nueva playlist</span>
                </button>
                <div className="max-h-56 overflow-y-auto">
                  {loadingPlaylists ? (
                    <div className="flex justify-center py-6">
                      <div className="w-5 h-5 border-2 border-white/20 border-t-white/60 rounded-full animate-spin" />
                    </div>
                  ) : playlists.length === 0 ? (
                    <p className="text-center text-white/40 text-sm py-6">No hay playlists disponibles</p>
                  ) : (
                    playlists.map(pl => (
                      <button key={pl.id} className="w-full flex items-center justify-between gap-3 px-4 py-3.5 border-b border-white/[0.04] hover:bg-white/5 active:bg-white/10 transition-colors text-left last:border-0" onClick={() => handleAddToPlaylist(pl.id)}>
                        <span className="text-white text-[15px] truncate">{pl.name}</span>
                        {addingToPlaylist === pl.id && <CheckIcon className="w-4 h-4 text-green-400 flex-shrink-0" />}
                      </button>
                    ))
                  )}
                </div>
              </>
            )}
          </div>

          {/* Cancel */}
          <button className="mx-3 mb-3 w-[calc(100%-1.5rem)] py-4 bg-[#2c2c2e] rounded-2xl text-[#0a84ff] font-semibold text-[17px] hover:bg-[#3a3a3c] active:bg-[#3a3a3c] transition-colors" onClick={handleClose}>
            Cancelar
          </button>
        </div>

        {showUpdatePlayCountModal && (
          <UpdatePlayCountModal song={song} onClose={() => { setShowUpdatePlayCountModal(false); handleClose() }} />
        )}
        {showSmartTagModal && (
          <SmartTagModal song={song} onClose={() => { setShowSmartTagModal(false); handleClose() }} />
        )}
        <CreatePlaylistModal
          isOpen={showCreatePlaylistModal}
          onClose={() => setShowCreatePlaylistModal(false)}
          onConfirm={handleCreateAndAddToPlaylist}
        />
      </>,
      document.body
    )
  }

  // ── Desktop: floating popover ────────────────────────────────────────────────
  return createPortal(
    <>
      <div className="fixed inset-0 z-[9998]" onClick={onClose} />
      <motion.div
        initial={{ opacity: 0, scale: 0.96, y: -4 }}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        exit={{ opacity: 0, scale: 0.96, y: -4 }}
        transition={{ duration: 0.1 }}
        style={{ top: y, left: x }}
        className="fixed bg-white/90 dark:bg-[#2c2c2e]/95 backdrop-blur-xl shadow-2xl rounded-2xl p-1.5 z-[9999] text-sm text-gray-900 dark:text-white border border-white/20 dark:border-white/10 min-w-[220px]"
      >
        <ul className="flex flex-col">
          <li onClick={handleAddToQueue} className="flex items-center gap-3 px-3 py-2.5 hover:bg-black/5 dark:hover:bg-white/5 rounded-xl cursor-pointer transition-colors">
            <QueueListIcon className="w-4 h-4 text-gray-500 dark:text-white/60" />
            <span>Añadir a la cola</span>
          </li>

          <li
            onMouseEnter={() => setShowPlaylistSubmenu(true)}
            onMouseLeave={() => setShowPlaylistSubmenu(false)}
            className="relative flex items-center justify-between gap-3 px-3 py-2.5 hover:bg-black/5 dark:hover:bg-white/5 rounded-xl cursor-pointer transition-colors"
          >
            <div className="flex items-center gap-3">
              <PlusCircleIcon className="w-4 h-4 text-gray-500 dark:text-white/60" />
              <span>Añadir a playlist</span>
            </div>
            <ChevronRightIcon className="w-3.5 h-3.5 text-gray-400 dark:text-white/30" />
            <AnimatePresence>
              {showPlaylistSubmenu && (
                <motion.div
                  initial={{ opacity: 0, x: -5 }}
                  animate={{ opacity: 1, x: 0 }}
                  exit={{ opacity: 0, x: -5 }}
                  transition={{ duration: 0.1 }}
                  className="absolute left-full top-0 ml-1.5 bg-white/90 dark:bg-[#2c2c2e]/95 backdrop-blur-xl shadow-2xl rounded-2xl p-1.5 border border-white/20 dark:border-white/10 min-w-[220px] max-h-[280px] overflow-y-auto"
                  onClick={e => e.stopPropagation()}
                >
                  <div onClick={() => setShowCreatePlaylistModal(true)} className="flex items-center gap-3 px-3 py-2.5 hover:bg-black/5 dark:hover:bg-white/5 rounded-xl cursor-pointer transition-colors border-b border-gray-200/60 dark:border-white/[0.06] mb-1">
                    <PlusCircleIcon className="w-4 h-4 text-blue-500 dark:text-[#0a84ff] flex-shrink-0" />
                    <span className="text-blue-500 dark:text-[#0a84ff]">Nueva playlist</span>
                  </div>
                  {loadingPlaylists ? (
                    <div className="px-3 py-2.5 text-gray-500 dark:text-white/40 text-sm">Cargando...</div>
                  ) : playlists.length === 0 ? (
                    <div className="px-3 py-2.5 text-gray-500 dark:text-white/40 text-sm">No hay playlists disponibles</div>
                  ) : (
                    playlists.map(pl => (
                      <div key={pl.id} onClick={() => handleAddToPlaylist(pl.id)} className="flex items-center justify-between gap-2 px-3 py-2.5 hover:bg-black/5 dark:hover:bg-white/5 rounded-xl cursor-pointer transition-colors">
                        <span className="truncate">{pl.name}</span>
                        {addingToPlaylist === pl.id && <CheckIcon className="w-4 h-4 text-green-500 flex-shrink-0" />}
                      </div>
                    ))
                  )}
                </motion.div>
              )}
            </AnimatePresence>
          </li>

          <div className="border-t border-gray-200/80 dark:border-white/[0.08] my-1 mx-1" />

          {showGoToArtist && (
            <li onClick={handleGoToArtist} className="flex items-center gap-3 px-3 py-2.5 hover:bg-black/5 dark:hover:bg-white/5 rounded-xl cursor-pointer transition-colors">
              <UserIcon className="w-4 h-4 text-gray-500 dark:text-white/60" />
              <span>Ir al artista</span>
            </li>
          )}
          {showGoToAlbum && song.albumId && (
            <li onClick={handleGoToAlbum} className="flex items-center gap-3 px-3 py-2.5 hover:bg-black/5 dark:hover:bg-white/5 rounded-xl cursor-pointer transition-colors">
              <VinylIcon className="w-4 h-4 text-gray-500 dark:text-white/60" />
              <span>Ir al álbum</span>
            </li>
          )}
          {showGoToSong && (
            <li onClick={handleGoToSong} className="flex items-center gap-3 px-3 py-2.5 hover:bg-black/5 dark:hover:bg-white/5 rounded-xl cursor-pointer transition-colors">
              <MusicalNoteIcon className="w-4 h-4 text-gray-500 dark:text-white/60" />
              <span>Ir a la canción</span>
            </li>
          )}

          {isAdmin && (
            <>
              <div className="border-t border-gray-200/80 dark:border-white/[0.08] my-1 mx-1" />
              <li onClick={e => { e.stopPropagation(); setShowUpdatePlayCountModal(true) }} className="flex items-center gap-3 px-3 py-2.5 hover:bg-black/5 dark:hover:bg-white/5 rounded-xl cursor-pointer transition-colors">
                <HashtagIcon className="w-4 h-4 text-gray-500 dark:text-white/60" />
                <span>Actualizar reproducciones</span>
              </li>
              <li onClick={e => { e.stopPropagation(); setShowSmartTagModal(true) }} className="flex items-center gap-3 px-3 py-2.5 hover:bg-black/5 dark:hover:bg-white/5 rounded-xl cursor-pointer transition-colors">
                <TagIcon className="w-4 h-4 text-gray-500 dark:text-white/60" />
                <span>Editar etiquetas</span>
              </li>
            </>
          )}
        </ul>
      </motion.div>

      {showUpdatePlayCountModal && (
        <UpdatePlayCountModal song={song} onClose={() => { setShowUpdatePlayCountModal(false); onClose() }} />
      )}
      {showSmartTagModal && (
        <SmartTagModal song={song} onClose={() => { setShowSmartTagModal(false); onClose() }} />
      )}
      <CreatePlaylistModal
        isOpen={showCreatePlaylistModal}
        onClose={() => setShowCreatePlaylistModal(false)}
        onConfirm={handleCreateAndAddToPlaylist}
      />
    </>,
    document.body
  )
}
