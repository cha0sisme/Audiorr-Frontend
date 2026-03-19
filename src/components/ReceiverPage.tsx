import React, { useEffect } from 'react';
import { useConnect } from '../hooks/useConnect';
import { usePlayerState } from '../contexts/PlayerContext';
import UniversalCover from './UniversalCover';
import { motion, AnimatePresence } from 'framer-motion';

export const ReceiverPage: React.FC = () => {
  const { isReceiverMode, setReceiverMode, isConnected, sendRemoteCommand } = useConnect();
  const playerState = usePlayerState();
  const { currentSong } = playerState;

  useEffect(() => {
    // Activar modo receptor al entrar en esta ruta
    if (!isReceiverMode) {
      setReceiverMode(true);
    }
    
    // Remote control via keyboard (Tizen / TV Remote)
    const handleKeyDown = (e: KeyboardEvent) => {
      console.log('[Receiver] Key pressed:', e.key);
      switch(e.key) {
        case 'ArrowRight':
          sendRemoteCommand('next', null);
          break;
        case 'ArrowLeft':
          sendRemoteCommand('previous', null);
          break;
        case ' ': // Space
          sendRemoteCommand('toggle_play', null);
          break;
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isReceiverMode, setReceiverMode, sendRemoteCommand]);

  if (!isConnected) {
    return (
      <div className="min-h-screen bg-black flex items-center justify-center text-white">
        <div className="text-center">
          <div className="w-16 h-16 border-4 border-green-500 border-t-transparent rounded-full animate-spin mx-auto mb-4"></div>
          <p className="text-xl font-medium opacity-50">Conectando con Audiorr Hub...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="fixed inset-0 bg-black overflow-hidden flex items-center justify-center">
      {/* Background Ambience */}
      <AnimatePresence mode="wait">
        {currentSong && (
          <motion.div
            key={currentSong.id}
            initial={{ opacity: 0 }}
            animate={{ opacity: 0.4 }}
            exit={{ opacity: 0 }}
            className="absolute inset-0 z-0"
            style={{
              backgroundImage: `url(${currentSong.coverArt})`,
              backgroundSize: 'cover',
              backgroundPosition: 'center',
              filter: 'blur(100px) saturate(2)',
            }}
          />
        )}
      </AnimatePresence>

      <div className="relative z-10 w-full max-w-6xl px-12 flex flex-col items-center gap-12">
        {/* Cover Art Section */}
        <div className="w-[45vh] h-[45vh] shadow-[0_50px_100px_-20px_rgba(0,0,0,0.8)] rounded-2xl overflow-hidden">
          <UniversalCover
            type="song"
            coverArtId={currentSong?.id}
            artistName={currentSong?.artist}
            alt={currentSong?.title}
            customCoverUrl={currentSong?.coverArt}
          />
        </div>

        {/* Metadata section */}
        <div className="text-center space-y-4 max-w-3xl">
          <motion.h1
            key={currentSong?.title}
            initial={{ y: 20, opacity: 0 }}
            animate={{ y: 0, opacity: 1 }}
            className="text-6xl font-black text-white tracking-tight truncate leading-tight"
          >
            {currentSong?.title || 'Esperando música...'}
          </motion.h1>
          <motion.p
            key={currentSong?.artist}
            initial={{ y: 20, opacity: 0 }}
            animate={{ y: 0, opacity: 0.7 }}
            transition={{ delay: 0.1 }}
            className="text-3xl font-medium text-white/70"
          >
            {currentSong?.artist} {currentSong?.album ? `— ${currentSong.album}` : ''}
          </motion.p>
        </div>

        {/* Status Indicator */}
        <div className="flex items-center gap-6 px-8 py-3 bg-white/5 backdrop-blur-3xl rounded-full border border-white/10 text-white/40 text-sm font-black tracking-[0.2em] uppercase">
          <div className={`w-3 h-3 rounded-full ${isConnected ? 'bg-green-400 shadow-[0_0_20px_rgba(74,222,128,0.6)]' : 'bg-red-500'} animate-pulse`} />
          Audiorr Connect Hub Connected
        </div>
      </div>
    </div>
  );
};
