import React, { useEffect, useState, useRef, useCallback, useMemo } from 'react';
import { io, Socket } from 'socket.io-client';
import { usePlayerState, usePlayerActions, usePlayerProgress, ScrobbleEventData } from './PlayerContext';

import { Device, PlaybackState, CastSession } from '../types/connect';
import { navidromeApi, Song } from '../services/navidromeApi';
import { backendApi } from '../services/backendApi';
import { ConnectContext } from './ConnectContextObject';

// --- Utils ---

/** Devuelve una clave de localStorage prefijada con el username para aislar estado entre usuarios */
function connectUserKey(key: string): string {
  const username = navidromeApi.getConfig()?.username;
  return username ? `${key}_${username}` : key;
}

const generateDeviceId = () => {
  const key = connectUserKey('audiorr_device_id');
  const existingId = localStorage.getItem(key);
  if (existingId) return existingId;

  let newId;
  if (typeof crypto !== 'undefined' && crypto.randomUUID) {
    newId = crypto.randomUUID();
  } else {
    // Fallback para contextos no seguros (HTTP) o navegadores antiguos sin Web Crypto API
    newId = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0;
      const v = c === 'x' ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }

  localStorage.setItem(key, newId);
  return newId;
};

const getDeviceName = () => {
  const ua = window.navigator.userAgent;
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/iPad/.test(ua)) return 'iPad';
  if (/Android.*Mobile/.test(ua)) return 'Android';
  if (/Android/.test(ua)) return 'Tablet';
  if (/Macintosh/.test(ua)) return 'Mac';
  if (/Windows/.test(ua)) return 'Windows PC';
  if (/Linux/.test(ua)) return 'Linux';
  return 'Dispositivo';
};

// --- Provider ---

export const ConnectProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  // 1. Estado Base
  const [socket, setSocket] = useState<Socket | null>(null);
  const [isConnected, setIsConnected] = useState(false);
  const [isConnecting, setIsConnecting] = useState(false);
  const [devices, setDevices] = useState<Device[]>([]);
  const [lanDevices, setLanDevices] = useState<Device[]>([]);
  const [remotePlaybackState, setRemotePlaybackState] = useState<PlaybackState | null>(null);
  const [activeDeviceId, setActiveDeviceId] = useState<string | null>(null);
  const [castSession, setCastSession] = useState<CastSession>({ active: false });
  const [isReceiverMode, setIsReceiverMode] = useState(() => localStorage.getItem(connectUserKey('audiorr_receiver_mode')) === 'true');
  const [lastError, setLastError] = useState<string | null>(null);
  const [reconnectKey, setReconnectKey] = useState(0);

  // 2. Config & ID
  const currentDeviceId = useMemo(() => generateDeviceId(), []);
  const deviceName = useMemo(() => getDeviceName(), []);

  // Tab sync (BroadcastChannel — same browser, different tabs)
  const tabId = useMemo(() => {
    try { return crypto.randomUUID(); }
    catch { return Math.random().toString(36).slice(2); }
  }, []);
  const tabChannel = useMemo(() => {
    try { return new BroadcastChannel(connectUserKey('audiorr-tab-sync')); }
    catch { return null; }
  }, []);

  const connectUrl = useMemo(() => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const runtimeUrl = (window as any).__AUDIORR_BACKEND_URL__ as string | undefined;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const envUrl = (import.meta as any).env.VITE_API_URL as string | undefined;
    return (runtimeUrl || envUrl || `${window.location.protocol}//${window.location.hostname}:2999`).replace(/\/$/, '');
  }, []);

  // 3. Player Hooks
  const playerState = usePlayerState();
  const playerActions = usePlayerActions();
  const playerProgress = usePlayerProgress();

  // 4. Refs para evitar loops y manejar drift
  const lastUpdateSentRef = useRef<number>(0);
  const isSyncingFromTabRef = useRef(false);
  const serverOffsetRef = useRef<number>(0);
  const handleRemoteCommandRef = useRef<(action: string, value: unknown) => void>(() => {});
  const syncStateToPlayerRef = useRef<(state: PlaybackState, restoreOnly?: boolean) => void>(() => {});
  const activeDeviceIdRef = useRef<string | null>(null);
  // Track whether the initial sync has been processed (for auto-controller logic)
  const hasDoneInitialSyncRef = useRef<boolean>(false);
  // Refs so socket listeners can read current player state without stale closures
  const currentSongRef = useRef(playerState.currentSong);
  const isPlayingRef = useRef(playerState.isPlaying);

  // --- Logic ---

  const syncStateToPlayer = useCallback((state: PlaybackState, restoreOnly = false) => {
    // 1. Sincronizar Canción y Cola si han cambiado
    const stateQueue = state.queue as Song[];
    const isDifferentSong = state.trackId !== playerState.currentSong?.id;
    const isDifferentQueue = stateQueue.length > 0 &&
      (stateQueue.length !== playerState.queue.length ||
       stateQueue[0]?.id !== playerState.queue[0]?.id);
    const isDifferentSource = state.currentSource !== playerState.currentSource;

    if (isDifferentSong || isDifferentQueue || isDifferentSource) {
      console.log('[Connect] Syncing song/queue/source to player', {
        song: state.trackId,
        position: state.position,
        source: state.currentSource,
        queueSize: stateQueue.length,
        restoreOnly,
      });

      if (state.trackId && stateQueue.length > 0) {
        const songToPlay = stateQueue.find(s => s.id === state.trackId);
        if (songToPlay) {
          playerActions.playSongAtPosition?.(stateQueue, songToPlay, state.position, !restoreOnly);
        }
      } else if (!restoreOnly && stateQueue.length > 0) {
        playerActions.playPlaylist?.(stateQueue);
      }
      return;
    }

    if (restoreOnly) return;

    // 2. Sincronizar Play/Pause (solo para misma canción)
    if (state.playing && !playerState.isPlaying) {
      playerActions.togglePlayPause?.();
    } else if (!state.playing && playerState.isPlaying) {
      playerActions.togglePlayPause?.();
    }

    // 3. Sincronizar posición si el drift es > 2s (solo para misma canción)
    const currentPos = playerProgress.progress;
    if (Math.abs(currentPos - state.position) > 2) {
      playerActions.seek?.(state.position);
    }

    // 4. Sincronizar Volumen
    if (state.volume !== undefined && Math.abs((playerState.volume || 0) - state.volume) > 0.05) {
      playerActions.setVolume?.(state.volume);
    }
  }, [
    playerState.currentSong, 
    playerState.queue, 
    playerState.currentSource, 
    playerState.isPlaying,
    playerState.volume,
    playerActions, 
    playerProgress.progress
  ]);

  const handleRemoteCommand = useCallback((action: string, value: unknown) => {
    switch (action) {
      case 'play': if (!playerState.isPlaying) playerActions.togglePlayPause?.(); break;
      case 'pause': if (playerState.isPlaying) playerActions.togglePlayPause?.(); break;
      case 'next': playerActions.next?.(); break;
      case 'previous': playerActions.previous?.(); break;
      case 'volume': playerActions.setVolume?.(value as number); break;
      case 'seek': playerActions.seek?.(value as number); break;
      case 'play_song': {
        const payload = value as { song: Song, queue: Song[] };
        playerActions.playPlaylistFromSong?.(payload.queue, payload.song);
        break;
      }
      case 'play_playlist': {
        const songs = value as Song[];
        playerActions.playPlaylist?.(songs);
        break;
      }
      case 'take_over_playback': {
        // Transferencia de reproducción: iniciar localmente desde la posición exacta del otro dispositivo
        const state = value as { trackId: string | null; queue: Song[]; position: number; currentSource?: string | null; smartMixPlaylistId?: string | null };
        if (state.trackId && state.queue.length > 0) {
          const songToPlay = state.queue.find((s: Song) => s.id === state.trackId);
          if (songToPlay) {
            console.log(`[Connect] Taking over playback: "${songToPlay.title}" at ${Math.round(state.position)}s`);
            playerActions.playSongAtPosition?.(state.queue, songToPlay, state.position);
            // Restaurar estado del smart mix si el dispositivo emisor estaba en uno
            if (state.smartMixPlaylistId) {
              playerActions.checkCachedSmartMix?.(state.smartMixPlaylistId, 'fast_check');
            }
          }
        }
        break;
      }
    }
  }, [playerActions, playerState.isPlaying]);

  const sendRemoteCommand = useCallback((action: string, value: unknown, targetDeviceId?: string) => {
    if (!socket) return;

    const target = targetDeviceId || activeDeviceId;
    if (!target) return;

    const targetDevice = devices.find(d => d.id === target) || lanDevices.find(d => d.id === target);

    if (targetDevice && targetDevice.type === 'lan_device') {
      // Logic for LAN devices (Google Cast, etc)
      if (action === 'play_song') {
        const payload = value as { song: Song, queue: Song[] };
        const streamUrl = navidromeApi.getStreamUrl(payload.song.id, payload.song.path);
        const coverArtUrl = navidromeApi.getCoverUrl(payload.song.coverArt) || undefined;

        console.log(`[Connect] Casting "${payload.song.title}" to ${targetDevice.name} -> ${streamUrl}`);
        socket.emit('cast_to_device', {
          deviceId: targetDevice.id,
          url: streamUrl,
          metadata: {
            title: payload.song.title,
            artist: payload.song.artist,
            album: payload.song.album,
            coverArtUrl,
          },
        });
      } else if (action === 'play_playlist') {
        // Cast first song of the playlist
        const songs = value as Song[];
        if (songs.length > 0) {
          const streamUrl = navidromeApi.getStreamUrl(songs[0].id, songs[0].path);
          const coverArtUrl = navidromeApi.getCoverUrl(songs[0].coverArt) || undefined;
          console.log(`[Connect] Casting playlist first song "${songs[0].title}" to ${targetDevice.name}`);
          socket.emit('cast_to_device', {
            deviceId: targetDevice.id,
            url: streamUrl,
            metadata: {
              title: songs[0].title,
              artist: songs[0].artist,
              album: songs[0].album,
              coverArtUrl,
            },
          });
        }
      } else if (action === 'pause') {
        socket.emit('cast_control', { action: 'pause' });
      } else if (action === 'play') {
        socket.emit('cast_control', { action: 'resume' });
      } else if (action === 'seek') {
        socket.emit('cast_control', { action: 'seekTo', value: value as number });
      } else if (action === 'volume') {
        socket.emit('cast_control', { action: 'setVolume', value: value as number });
      } else {
        // next/previous and other commands pass through as remote_command
        socket.emit('remote_command', { action, value, targetDeviceId: target });
      }
    } else {
      // Normal Audiorr Connect device
      socket.emit('remote_command', { action, value, targetDeviceId: target });
    }
  }, [socket, activeDeviceId, devices, lanDevices]);

  // Sincronizar handlers remotos con PlayerContext
  useEffect(() => {
    if (activeDeviceId && activeDeviceId !== currentDeviceId) {
      console.log(`[Connect] Hijacking player actions for remote device: ${activeDeviceId}`);
      playerActions.registerRemoteHandlers({
        playSong: (song, queue) => sendRemoteCommand('play_song', { song, queue }),
        playPlaylist: (songs) => sendRemoteCommand('play_playlist', songs),
        togglePlayPause: () => sendRemoteCommand(playerState.isPlaying ? 'pause' : 'play', null),
        seek: (time) => sendRemoteCommand('seek', time),
        next: () => sendRemoteCommand('next', null),
        previous: () => sendRemoteCommand('previous', null),
        setVolume: (vol) => sendRemoteCommand('volume', vol),
      });
    } else {
      playerActions.registerRemoteHandlers(null);
    }
    
    return () => {
      playerActions.registerRemoteHandlers(null);
    };
  }, [activeDeviceId, currentDeviceId, sendRemoteCommand, playerState.isPlaying, playerActions]);

  // Mantener refs sincronizados
  useEffect(() => { handleRemoteCommandRef.current = handleRemoteCommand; }, [handleRemoteCommand]);
  useEffect(() => { syncStateToPlayerRef.current = syncStateToPlayer; }, [syncStateToPlayer]);
  useEffect(() => { activeDeviceIdRef.current = activeDeviceId; }, [activeDeviceId]);
  useEffect(() => { currentSongRef.current = playerState.currentSong; }, [playerState.currentSong]);
  useEffect(() => { isPlayingRef.current = playerState.isPlaying; }, [playerState.isPlaying]);

  // Suprimir scrobbles cuando el dispositivo está en modo receiver:
  // el receiver actúa como altavoz — no debe registrar reproducciones propias.
  useEffect(() => {
    playerActions.setScrobblingSuppressed(isReceiverMode);
  }, [isReceiverMode, playerActions]);

  // --- Tab Sync (BroadcastChannel) ---

  // Receive discrete state changes from sibling tabs in the same browser
  useEffect(() => {
    if (!tabChannel) return;
    const handler = (event: MessageEvent<{ tabId: string; state: PlaybackState }>) => {
      if (event.data.tabId === tabId) return; // own tab
      if (isReceiverMode) return; // receiver has its own sync source
      if (activeDeviceIdRef.current && activeDeviceIdRef.current !== currentDeviceId) return; // controlling remote device
      console.log('[TabSync] Syncing state from sibling tab');
      isSyncingFromTabRef.current = true;
      syncStateToPlayerRef.current(event.data.state);
      setTimeout(() => { isSyncingFromTabRef.current = false; }, 200);
    };
    tabChannel.addEventListener('message', handler);
    return () => { tabChannel.removeEventListener('message', handler); };
  }, [tabChannel, tabId, isReceiverMode, currentDeviceId]);

  // Broadcast discrete state changes to sibling tabs (song, play/pause, volume, queue)
  // NOTE: playerProgress.progress is intentionally excluded from deps — we don't want
  // to broadcast every position tick, only meaningful state changes.
  useEffect(() => {
    if (!tabChannel) return;
    if (isReceiverMode) return; // receivers are silent
    if (isSyncingFromTabRef.current) return; // don't echo back a received sync
    if (!playerState.currentSong) return;
    tabChannel.postMessage({
      tabId,
      state: {
        trackId: playerState.currentSong.id,
        metadata: {
          title: playerState.currentSong.title,
          artist: playerState.currentSong.artist,
          album: playerState.currentSong.album,
          coverArt: playerState.currentSong.coverArt,
          duration: playerState.currentSong.duration,
        },
        position: playerProgress.progress,
        startedAt: Date.now() - (playerProgress.progress * 1000),
        playing: playerState.isPlaying,
        volume: playerState.volume,
        queue: playerState.queue,
        currentSource: playerState.currentSource,
        deviceId: currentDeviceId,
      } as PlaybackState,
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    playerState.currentSong, playerState.isPlaying, playerState.volume,
    playerState.queue, playerState.currentSource, isReceiverMode,
    tabChannel, tabId, currentDeviceId,
    // playerProgress.progress excluded intentionally
  ]);

  // Close BroadcastChannel on unmount
  useEffect(() => {
    return () => { tabChannel?.close(); };
  }, [tabChannel]);

  // --- Socket Setup ---

  useEffect(() => {
    let cancelled = false;
    let socketRef: Socket | null = null;
    hasDoneInitialSyncRef.current = false;

    const setup = async () => {
      let token = localStorage.getItem(connectUserKey('audiorr_session_token'));

      if (!token) {
        const rawNavConfig = localStorage.getItem('navidromeConfig');
        if (!rawNavConfig) return;
        try {
          setIsConnecting(true);
          const navConfig = JSON.parse(rawNavConfig);
          const auth = await backendApi.login(navConfig);
          token = auth.token;
          localStorage.setItem(connectUserKey('audiorr_session_token'), auth.token);
        } catch (err) {
          if (!cancelled) {
            setIsConnecting(false);
            setLastError('Auto-login fallido: ' + (err instanceof Error ? err.message : String(err)));
          }
          return;
        }
      }

      if (cancelled) return;

      setIsConnecting(true);
      console.log('[Connect] Connecting to Hub at:', connectUrl);

      const newSocket = io(connectUrl, {
        auth: { token },
        reconnection: true,
        reconnectionAttempts: Infinity,
        reconnectionDelay: 1000,
        reconnectionDelayMax: 30000,
        timeout: 10000,
      });
      socketRef = newSocket;

      newSocket.on('connect', () => {
        setIsConnected(true);
        setIsConnecting(false);
        setLastError(null);
        console.log('[Connect] Connected to Hub');

        newSocket.emit('register_device', {
          id: currentDeviceId,
          name: deviceName,
          type: isReceiverMode ? 'receiver' : 'hybrid',
        });

        newSocket.emit('request_sync');

        // Registrar scrobbles via Socket.io (solo si no somos receiver)
        // Esto permite al backend deduplicar correctamente en wrapped.db
        if (!isReceiverMode) {
          playerActions.setScrobbleCallback((data: ScrobbleEventData) => {
            newSocket.emit('scrobble', data);
          });
        }
        
        // Obtener IP del servidor para Cast (opcional, solo log por ahora)
        backendApi.getHubStatus().then((status: { serverIp?: string }) => {
          if (status.serverIp) console.log('[Connect] Server LAN IP:', status.serverIp);
        }).catch((e: Error) => console.warn('[Connect] Could not fetch server IP', e));
      });

      newSocket.on('connect_error', (error) => {
        console.error('[Connect] Connection error:', error.message);
        setIsConnecting(false);
        setIsConnected(false);
        setLastError(error.message);
        if (error.message.toLowerCase().includes('auth') || error.message.toLowerCase().includes('token')) {
          localStorage.removeItem(connectUserKey('audiorr_session_token'));
        }
      });

      newSocket.on('disconnect', () => {
        setIsConnected(false);
        // Limpiar sesión remota: si controlábamos un dispositivo, ya no podemos comunicarnos
        if (activeDeviceIdRef.current) {
          console.log('[Connect] Disconnected — clearing remote session');
          activeDeviceIdRef.current = null;
          setActiveDeviceId(null);
          setRemotePlaybackState(null);
        }
        console.log('[Connect] Disconnected');
      });

      newSocket.on('devices_list', (list: Device[]) => {
        setDevices(list);
      });

      newSocket.on('lan_devices_discovered', (list: Device[]) => {
        setLanDevices(list);
      });

      newSocket.on('playback_state_update', (state: PlaybackState) => {
        if (state.deviceId === currentDeviceId) return;

        if (state.serverTime) {
          serverOffsetRef.current = state.serverTime - Date.now();
        }

        setRemotePlaybackState(state);

        // ── Restauración inicial cross-device ────────────────────────────────
        // Cuando este dispositivo no tiene ninguna canción (recién abierto) y llega
        // el primer sync del backend (respuesta a request_sync), restauramos el último
        // estado de reproducción de forma pausada. El usuario puede pulsar play para
        // continuar exactamente donde estaba en el otro dispositivo.
        if (!hasDoneInitialSyncRef.current) {
          hasDoneInitialSyncRef.current = true;
          if (!currentSongRef.current && state.trackId && state.queue?.length) {
            console.log('[Connect] Cross-device restore: restoring last playback state (paused)');
            syncStateToPlayerRef.current(state, true); // restoreOnly=true → no autoplay
            return;
          }
        }

        // Auto-controller: become controller whenever another device is actively playing
        // and we are NOT actively playing locally (paused or no song counts as idle).
        // Fires on initial connect AND whenever a device starts playing while we're idle.
        // Does NOT send any command to the remote device — it just routes local actions to it.
        const isLocallyPlaying = !!currentSongRef.current && isPlayingRef.current;
        if (!isReceiverMode && !activeDeviceIdRef.current && !isLocallyPlaying && state.trackId && state.playing && state.metadata) {
          console.log(`[Connect] Auto-controller: ${state.deviceId} is playing, becoming controller`);
          activeDeviceIdRef.current = state.deviceId;
          setActiveDeviceId(state.deviceId);
          return;
        }

        // Receiver mode: sync the remote state into the local player
        if (isReceiverMode) {
          syncStateToPlayerRef.current(state);
        }
      });

      newSocket.on('remote_command', (cmd: { action: string, value: unknown, targetDeviceId?: string }) => {
        if (cmd.targetDeviceId && cmd.targetDeviceId !== currentDeviceId) return;
        console.log(`[Connect] Remote command received: ${cmd.action}`, cmd.value);
        handleRemoteCommandRef.current(cmd.action, cmd.value);
      });

      newSocket.on('cast_session_update', (update: CastSession) => {
        console.log('[Connect] Cast session update:', update);
        setCastSession(update);
      });

      if (!cancelled) {
        setSocket(newSocket);
      } else {
        newSocket.disconnect();
      }
    };

    setup();

    return () => {
      cancelled = true;
      socketRef?.disconnect();
      playerActions.setScrobbleCallback(null);
    };
  }, [currentDeviceId, isReceiverMode, deviceName, reconnectKey, connectUrl]);

  const setReceiverMode = (enabled: boolean) => {
    setIsReceiverMode(enabled);
    localStorage.setItem(connectUserKey('audiorr_receiver_mode'), String(enabled));
    if (socket) {
      socket.emit('register_device', {
        id: currentDeviceId,
        name: deviceName,
        type: enabled ? 'receiver' : 'hybrid',
      });
    }
  };

  const transferPlayback = (targetDeviceId: string) => {
    if (!socket) return;
    
    // Si transferimos a nosotros mismos, simplemente marcamos como activo local
    if (targetDeviceId === currentDeviceId) {
      setActiveDeviceId(null); // NULL significa local
      return;
    }

    // Si no estamos reproduciendo activamente (canción en pausa o sin canción),
    // simplemente nos convertimos en controlador del dispositivo destino sin enviar
    // ningún comando — así no se interrumpe lo que ya está sonando en ese dispositivo.
    // Pedimos sync al hub para recibir el estado actual del dispositivo remoto.
    if (!playerState.currentSong || !playerState.isPlaying) {
      setActiveDeviceId(targetDeviceId);
      socket.emit('request_sync');
      return;
    }

    // Capturar posición actual antes de pausar
    const transferPosition = playerProgress.progress;
    const transferQueue = playerState.queue;
    const transferSong = playerState.currentSong;

    // Publicar estado actual en el hub (para que quede persistido)
    socket.emit('playback_state_update', {
      trackId: transferSong?.id || null,
      metadata: transferSong ? {
        title: transferSong.title,
        artist: transferSong.artist,
        album: transferSong.album,
        coverArt: transferSong.coverArt,
        duration: transferSong.duration,
      } : null,
      position: transferPosition,
      startedAt: Date.now() - (transferPosition * 1000),
      playing: playerState.isPlaying,
      volume: playerState.volume,
      queue: transferQueue,
      currentSource: playerState.currentSource,
      deviceId: currentDeviceId,
    });

    // Ordenar al dispositivo destino que tome la reproducción desde nuestra posición exacta
    if (transferSong && transferQueue.length > 0) {
      socket.emit('remote_command', {
        action: 'take_over_playback',
        value: {
          trackId: transferSong.id,
          queue: transferQueue,
          position: transferPosition,
          currentSource: playerState.currentSource,
          smartMixPlaylistId: playerState.smartMixPlaylistId ?? null,
        },
        targetDeviceId,
      });
    }

    // Marcar ese dispositivo como el "target" para nuestros comandos remotos
    setActiveDeviceId(targetDeviceId);

    // Detener reproducción local cuando transferimos a fuera
    if (playerState.isPlaying) {
      playerActions.togglePlayPause?.();
    }
  };

  const castToLanDevice = (device: Device) => {
    if (!socket) return;
    console.log(`[Connect] Connecting to LAN device: ${device.name} (${device.ip})`);

    // Si hay una canción en reproducción, castearla inmediatamente
    if (playerState.currentSong) {
      const song = playerState.currentSong;
      const streamUrl = navidromeApi.getStreamUrl(song.id, song.path);
      const coverArtUrl = navidromeApi.getCoverUrl(song.coverArt) || undefined;

      console.log(`[Connect] Casting current song "${song.title}" to ${device.name} -> ${streamUrl}`);
      socket.emit('cast_to_device', {
        deviceId: device.id,
        url: streamUrl,
        metadata: {
          title: song.title,
          artist: song.artist,
          album: song.album,
          coverArtUrl,
        },
      });
    }

    // Registrar remote handlers y pausar reproducción local
    transferPlayback(device.id);
  };


  const stopCast = useCallback(() => {
    if (!socket) return;
    socket.emit('cast_control', { action: 'stop' });
    setCastSession({ active: false });
    setActiveDeviceId(null);
    playerActions.registerRemoteHandlers(null);
  }, [socket, playerActions]);

  const reconnect = useCallback(() => {
    setLastError(null);
    setIsConnecting(true);
    setIsConnected(false);
    setReconnectKey(k => k + 1);
  }, []);

  const subscribeToEvent = useCallback((event: string, handler: (data: unknown) => void) => {
    if (!socket) return () => {};
    socket.on(event, handler);
    return () => { socket.off(event, handler); };
  }, [socket]);

  // --- Detección de dispositivo remoto desconectado ---
  // Cuando el Hub envía una devices_list actualizada sin nuestro activeDeviceId,
  // el dispositivo controlado se fue (cerró sesión, apagó, etc.) → limpiar sesión.
  useEffect(() => {
    if (!activeDeviceId || activeDeviceId === currentDeviceId) return;
    // Comprobar si es un dispositivo LAN (cast) — esos no están en `devices`
    const isLanDevice = lanDevices.some(d => d.id === activeDeviceId);
    if (isLanDevice) return;
    // Si el dispositivo ya no existe en la lista, limpiar
    const stillExists = devices.some(d => d.id === activeDeviceId);
    if (!stillExists) {
      console.log(`[Connect] Active device ${activeDeviceId} disappeared — clearing remote session`);
      activeDeviceIdRef.current = null;
      setActiveDeviceId(null);
      setRemotePlaybackState(null);
    }
  }, [devices, lanDevices, activeDeviceId, currentDeviceId]);

  // --- Sincronización Inmediata ---
  useEffect(() => {
    if (!socket || !isConnected || isReceiverMode) return;
    // Controllers (activeDeviceId set to another device, not a Cast session) must not
    // broadcast their own player state — they would overwrite the source's state on the server.
    const isController = !!activeDeviceId && activeDeviceId !== currentDeviceId && !castSession.active;
    if (isController) return;

    const broadcastState = () => {
      const now = Date.now();
      socket.emit('playback_state_update', {
        trackId: playerState.currentSong?.id || null,
        metadata: playerState.currentSong ? {
          title: playerState.currentSong.title,
          artist: playerState.currentSong.artist,
          album: playerState.currentSong.album,
          coverArt: playerState.currentSong.coverArt,
          duration: playerState.currentSong.duration,
        } : null,
        position: playerProgress.progress,
        startedAt: Date.now() - (playerProgress.progress * 1000),
        playing: playerState.isPlaying,
        volume: playerState.volume,
        queue: playerState.queue,
        currentSource: playerState.currentSource,
        deviceId: currentDeviceId,
      });
      lastUpdateSentRef.current = now;
    };

    broadcastState();
  }, [
    socket, isConnected, isReceiverMode, currentDeviceId, activeDeviceId, castSession.active,
    playerState.currentSong, playerState.isPlaying, playerState.currentSource,
    playerState.volume, playerState.queue, playerProgress.progress
  ]);

  return (
    <ConnectContext.Provider value={{
      isConnected, isConnecting, devices, lanDevices, currentDeviceId,
      remotePlaybackState, activeDeviceId, isReceiverMode, lastError, connectUrl,
      castSession,
      setReceiverMode, transferPlayback, castToLanDevice, sendRemoteCommand, stopCast, reconnect, subscribeToEvent,
    }}>
      {children}
    </ConnectContext.Provider>
  );
};
