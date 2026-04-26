import AVFoundation
import MediaPlayer
// Capacitor removed — fully native

/// Motor de audio nativo basado en AVAudioEngine.
/// Grafo: playerA → timePitchA → dspNodeA → mixerA → mainMixer → limiter → output
///        playerB → timePitchB → dspNodeB → mixerB → mainMixer → limiter → output
///
/// DSP filters are custom biquad processors (BiquadDSPNode) — no AVAudioUnitEQ.
/// Gestiona reproducción, NowPlaying, remote commands e interrupciones.
class AudioEngineManager {

    // MARK: - Shared instance (para acceso desde CarPlay)
    static var shared: AudioEngineManager?

    // MARK: - Engine y nodos

    private let engine = AVAudioEngine()
    // playerA es siempre el "activo" — tras crossfade se swapean con playerB
    private var playerA: AVAudioPlayerNode
    private var playerB: AVAudioPlayerNode
    private var dspNodeA: BiquadDSPNode
    private var dspNodeB: BiquadDSPNode
    private var timePitchA: AVAudioUnitTimePitch
    private var timePitchB: AVAudioUnitTimePitch
    private var mixerA: AVAudioMixerNode
    private var mixerB: AVAudioMixerNode
    private let limiter: AVAudioUnitEffect

    // MARK: - Estado

    private(set) var isPlaying = false
    private var volume: Float = 0.75
    private(set) var currentSongDuration: Double = 0
    /// Effective end of audio (excluding trailing silence). Set from analysis data.
    /// Used by QueueManager to calculate crossfade trigger. 0 = not set (use full duration).
    private(set) var currentEffectiveEnd: Double = 0
    private var currentSongTitle: String = ""
    private var currentSongArtist: String = ""
    private var currentSongAlbum: String = ""

    private var currentFile: AVAudioFile?
    private var nextFile: AVAudioFile?
    private var replayGainMultiplierA: Float = 1.0
    private var replayGainMultiplierB: Float = 1.0

    // Tracking de tiempo para playerA
    private var playStartOffset: Double = 0 // offset en segundos dentro del archivo
    private var pauseSampleTime: AVAudioFramePosition = 0 // sampleTime al momento de pausar (evita double-counting)
    private var lastSeekTime: CFAbsoluteTime = 0 // para bloquear automix tras seek manual

    // Interrupciones
    private var wasPlayingBeforeInterruption = false
    private var commandCenterReady = false

    /// Diccionario local que mantiene el estado completo de NowPlaying.
    /// Siempre escribir a este dict y publicar con publishNowPlayingInfo().
    /// NUNCA leer del singleton MPNowPlayingInfoCenter.default().nowPlayingInfo
    /// (devuelve una copia y causa race conditions con read-modify-write).
    /// Esto también evita que WKWebView en Capacitor pueda borrar nuestra info.
    private var localNowPlayingInfo: [String: Any] = [:]

    // Play sequence counter: incremented on every play() call.
    // The completion handler captures the current value and only fires onTrackEnd
    // if it still matches — preventing stale handlers from old songs.
    private var playSequence: Int = 0

    // MARK: - Crossfade

    var crossfadeExecutor: CrossfadeExecutor?
    private(set) var isCrossfading = false
    private var crossfadeStartedAt: CFAbsoluteTime = 0

    // MARK: - Native Automix (background-safe)
    // Cuando JS está congelado (pantalla bloqueada), este timer nativo
    // verifica la posición y dispara el crossfade autónomamente.

    private var automixTimer: DispatchSourceTimer?
    /// Tiempo en la canción actual donde debe dispararse el crossfade.
    /// nil = no hay automix programado.
    private var automixTriggerTime: Double?

    /// Whether an automix trigger is currently armed (for external query).
    var automixHasTrigger: Bool { automixTriggerTime != nil }
    /// Config de crossfade calculada por JS — almacenada para ejecutar en background.
    private var pendingCrossfadeConfig: CrossfadeExecutor.Config?
    /// Metadata de la siguiente canción (para NowPlaying tras crossfade en background)
    private var nextSongTitle: String = ""
    private var nextSongArtist: String = ""
    private var nextSongAlbum: String = ""
    private var nextSongDuration: Double = 0
    /// Indica si hay una siguiente canción preparada para playback directo (next desde lock screen)
    var hasNextFilePrepared: Bool { nextFile != nil }
    /// URL de streaming de la siguiente canción — fallback si el archivo no descargó a tiempo.
    /// Se establece al inicio de prepareNext y se borra cuando nextFile llega o al iniciar nueva canción.
    private var nextStreamURL: URL?
    /// Timer del crossfade en modo stream fallback (sustituye a CrossfadeExecutor cuando nextFile == nil)
    private var streamFadeTimer: DispatchSourceTimer?
    private var streamFadeWatchdog: DispatchSourceTimer?

    // MARK: - Progress timer

    private var progressTimer: Timer?
    private let progressInterval: TimeInterval = 0.25 // 4Hz
    private var lastReportedTime: Double = 0
    private var stalledTickCount: Int = 0

    // Wall-clock fallback for currentTime() after crossfade.
    // When AudioUnitReset (or any DSP disruption) breaks playerTime(forNodeTime:),
    // this provides a smooth time estimate until playerTime recovers.
    private var postCrossfadeWallTime: Double = 0   // CACurrentMediaTime() when set
    private var postCrossfadeOffset: Double = 0     // song position at that moment

    // Grace period: SAFETY NET 2 ignores stalled progress for 5s after crossfade
    private var crossfadeCompletedAt: CFAbsoluteTime = 0

    // MARK: - Streaming mode (AVPlayer para canciones no cacheadas)
    // Cuando una canción no está en caché, usamos AVPlayer con la URL HTTP directamente
    // para arrancar en ~500ms (como Spotify). La descarga continúa en background para
    // cachear. La próxima vez, AVAudioEngine sirve el archivo local con crossfade completo.

    private var streamPlayer: AVPlayer?
    private var streamPlayerEndObserver: Any?
    private(set) var isStreamMode = false

    // MARK: - Native delegate (replaces plugin for native queue management)

    weak var delegate: AudioEngineDelegate?

    // MARK: - Init

    init() {
        // Crear nodos
        playerA = AVAudioPlayerNode()
        playerB = AVAudioPlayerNode()
        mixerA = AVAudioMixerNode()
        mixerB = AVAudioMixerNode()

        // TimePitch nodes for tempo adjustment during crossfade (rate only, no pitch change)
        timePitchA = AVAudioUnitTimePitch()
        timePitchB = AVAudioUnitTimePitch()

        // Custom DSP nodes: 4 biquad filters per chain for crossfade automation.
        // Replaces AVAudioUnitEQ — we own the coefficients, no stale IIR cache.
        // Band 0: highPass/lowPass (frequency sweep)
        // Band 1: lowShelf (bass management)
        // Band 2: parametric mid scoop (vocal anti-clash, ~1.5kHz)
        // Band 3: highShelf (hi-hat cleanup on A, ~8kHz)
        do {
            dspNodeA = try BiquadDSPNode()
            dspNodeB = try BiquadDSPNode()
        } catch {
            fatalError("[AudioEngineManager] Failed to create BiquadDSPNode: \(error)")
        }

        // PeakLimiter: prevents clipping when A+B overlap during crossfade.
        // Transparent when signal is below 0dBFS — only catches peaks.
        let limiterDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        limiter = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
        // Configure: fast attack, moderate release, no pre-gain
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.003, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.06, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)

        setupAudioGraph()
        setupObservers()
        setupCommandCenter()

        AudioEngineManager.shared = self
    }

    deinit {
        stopProgressTimer()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Audio Graph

    private func setupAudioGraph() {
        // Attach nodos
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(timePitchA)
        engine.attach(timePitchB)
        engine.attach(dspNodeA.node)
        engine.attach(dspNodeB.node)
        engine.attach(mixerA)
        engine.attach(mixerB)
        engine.attach(limiter)

        let mainMixer = engine.mainMixerNode

        // Usamos el formato del mainMixer para todas las conexiones intermedias.
        // AVAudioMixerNode convierte formatos automáticamente si hay mismatch.
        let format = mainMixer.outputFormat(forBus: 0)

        // Grafo A: playerA → timePitchA → dspNodeA → mixerA → mainMixer
        engine.connect(playerA, to: timePitchA, format: nil)
        engine.connect(timePitchA, to: dspNodeA.node, format: nil)
        engine.connect(dspNodeA.node, to: mixerA, format: nil)
        engine.connect(mixerA, to: mainMixer, format: format)

        // Grafo B: playerB → timePitchB → dspNodeB → mixerB → mainMixer
        engine.connect(playerB, to: timePitchB, format: nil)
        engine.connect(timePitchB, to: dspNodeB.node, format: nil)
        engine.connect(dspNodeB.node, to: mixerB, format: nil)
        engine.connect(mixerB, to: mainMixer, format: format)

        // Limiter: mainMixer → limiter → outputNode
        // Prevents clipping when both A+B are audible during crossfade overlap.
        // Transparent when signal is below 0dBFS.
        engine.connect(mainMixer, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)

        // Volumen inicial
        mainMixer.outputVolume = volume
        mixerA.outputVolume = 1.0
        mixerB.outputVolume = 0.0 // B silenciado hasta crossfade

        engine.prepare()
        print("[AudioEngineManager] Audio graph configurado (con limiter)")
    }

    /// Intenta arrancar el engine si no está corriendo.
    /// Retorna `true` si el engine está corriendo al finalizar, `false` si falló.
    @discardableResult
    private func ensureEngineRunning() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            print("[AudioEngineManager] Engine arrancado")
            return true
        } catch {
            print("[AudioEngineManager] Error arrancando engine: \(error)")
            delegate?.audioEngineError("Engine failed to start: \(error.localizedDescription)", code: "ENGINE_START_ERROR")
            return false
        }
    }

    // MARK: - Reproducción

    func play(fileURL: URL, startAt: Double, replayGainMultiplier: Float, duration: Double,
              title: String? = nil, artist: String? = nil, album: String? = nil) {
        // Guardar metadata inmediatamente si se proporciona, ANTES de tocar el engine.
        // Esto asegura que MPNowPlayingInfoCenter tenga título desde el primer momento,
        // necesario para que Dynamic Island muestre el reproductor.
        if let t = title, !t.isEmpty { currentSongTitle = t }
        if let a = artist               { currentSongArtist = a }
        if let al = album                { currentSongAlbum = al }
        // Si estábamos en modo streaming (AVPlayer), detenerlo antes de arrancar AVAudioEngine
        stopStreamPlayer()

        // Cancel any in-progress crossfade BEFORE touching players.
        // If the user taps "next" during a crossfade, playerB is actively fading in —
        // we must cancel the executor and stop playerB to prevent state corruption
        // (stale onComplete doing a swap after we've already moved on).
        // Uses cancelCrossfade() to ensure ALL cleanup: DSP reset, streamFadeWatchdog,
        // timePitch rates, and stream observer removal.
        if isCrossfading {
            cancelCrossfade()
            playerB.stop()
            print("[AudioEngineManager] play(): cancelled in-progress crossfade")
        }

        guard ensureEngineRunning() else {
            print("[AudioEngineManager] play() abortado: engine no arrancó")
            return
        }
        cancelNativeNextFallback()
        clearAutomixTrigger()

        // Invalidate any pending completion handlers from the previous song.
        playSequence += 1
        let thisPlaySeq = playSequence

        // Detener reproducción anterior
        playerA.stop()

        do {
            let file = try AVAudioFile(forReading: fileURL)
            currentFile = file
            // Prefer actual file duration over metadata — metadata from Navidrome can be wrong
            // (e.g. re-encoded files, VBR MP3s with bad headers). The file's frame count is ground truth.
            let fileDuration = Double(file.length) / file.processingFormat.sampleRate
            if fileDuration > 0 {
                currentSongDuration = fileDuration
                if duration > 0 && abs(fileDuration - duration) > 2.0 {
                    print("[AudioEngineManager] ⚠️ Duration mismatch: metadata=\(String(format: "%.1f", duration))s, file=\(String(format: "%.1f", fileDuration))s — using file duration")
                }
                // Reset effective end — will be set by QueueManager when analysis is available.
                currentEffectiveEnd = 0
            } else {
                currentSongDuration = duration > 0 ? duration : 0
                currentEffectiveEnd = 0
            }
            replayGainMultiplierA = replayGainMultiplier
            playStartOffset = startAt
            pauseSampleTime = 0
            postCrossfadeWallTime = 0
            postCrossfadeOffset = 0

            // Aplicar ReplayGain via mixerA
            mixerA.outputVolume = replayGainMultiplier

            // Asegurar EQ + pan en neutral para bandas de transición (no estamos en crossfade)
            dspNodeA.reset()
            dspNodeB.reset()
            mixerA.pan = 0
            mixerB.pan = 0

            // Forzar volumen maestro al valor actual del usuario
            engine.mainMixerNode.outputVolume = volume

            // Calcular frame de inicio
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(startAt * sampleRate)
            let totalFrames = file.length
            let framesToPlay = AVAudioFrameCount(totalFrames - startFrame)

            guard framesToPlay > 0 else {
                print("[AudioEngineManager] No hay frames para reproducir")
                delegate?.audioEngineError("No frames to play", code: "NO_FRAMES")
                return
            }

            // Programar segmento
            // Capturar referencia al player actual para verificar que sigue siendo
            // el activo cuando el completion handler se ejecute (tras un crossfade
            // playerA/B se intercambian y el handler del player viejo no debe disparar onTrackEnd).
            let activePlayer = playerA
            playerA.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay, at: nil) { [weak self] in
                // Completado en el render thread — dispatch al main para notificar
                DispatchQueue.main.async {
                    guard let self = self else { print("[AudioEngineManager] ⚠️ play() completion: self deallocated"); return }
                    guard self.isPlaying else { print("[AudioEngineManager] ⚠️ play() completion: isPlaying=false"); return }
                    // If A ended while crossfading, A has no more audio — force B to full volume
                    // immediately to prevent an audible gap. The executor will complete normally.
                    if self.isCrossfading {
                        print("[AudioEngineManager] ⚠️ play() completion: A ended during crossfade — rushing B to full volume")
                        self.mixerA.outputVolume = 0
                        self.mixerB.outputVolume = self.replayGainMultiplierB
                        return
                    }
                    guard self.playerA === activePlayer else { print("[AudioEngineManager] ⚠️ play() completion: playerA swapped"); return }
                    guard self.playSequence == thisPlaySeq else { print("[AudioEngineManager] ⚠️ play() completion: playSequence mismatch (have \(self.playSequence), expected \(thisPlaySeq))"); return }
                    self.isPlaying = false
                    self.stopProgressTimer()
                    self.updateNowPlayingPlaybackState()
                    self.delegate?.audioEngineDidFinishSong()
                    print("[AudioEngineManager] Track terminado (delegate=\(self.delegate != nil))")
                }
            }

            playerA.play()
            isPlaying = true

            // Validar que el player realmente arrancó tras un breve delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.isPlaying, self.playerA === activePlayer, self.playSequence == thisPlaySeq else { return }
                if self.playerA.lastRenderTime == nil || !self.engine.isRunning {
                    print("[AudioEngineManager] ⚠️ playerA no está renderizando — reiniciando engine")
                    self.isPlaying = false
                    self.delegate?.audioEngineError("Player failed to start rendering", code: "RENDER_FAILED")
                }
            }

            startProgressTimer()

            // Establecer NowPlaying info inmediatamente para que Dynamic Island aparezca.
            // Usar el diccionario local (nunca leer del singleton — race conditions con WKWebView).
            // Preservar artwork existente si la hay (reutilizar en caso de cambio de canción).
            let existingArtwork = localNowPlayingInfo[MPMediaItemPropertyArtwork]
            localNowPlayingInfo = [
                MPMediaItemPropertyPlaybackDuration: currentSongDuration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: startAt,
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            ]
            if !currentSongTitle.isEmpty {
                localNowPlayingInfo[MPMediaItemPropertyTitle] = currentSongTitle
                localNowPlayingInfo[MPMediaItemPropertyArtist] = currentSongArtist
                localNowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentSongAlbum
            }
            if let artwork = existingArtwork {
                localNowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            }
            publishNowPlayingInfo()
            MPNowPlayingInfoCenter.default().playbackState = .playing

            // Asegurar que los comandos remotos estén habilitados.
            // iOS puede deshabilitarlos tras interrupciones o cambios de ruta.
            let cc = MPRemoteCommandCenter.shared()
            cc.playCommand.isEnabled = true
            cc.pauseCommand.isEnabled = true
            cc.togglePlayPauseCommand.isEnabled = true
            cc.nextTrackCommand.isEnabled = true
            cc.previousTrackCommand.isEnabled = true
            cc.changePlaybackPositionCommand.isEnabled = true

            print("[AudioEngineManager] Play: \(fileURL.lastPathComponent) desde \(String(format: "%.1f", startAt))s (RG: \(String(format: "%.3f", replayGainMultiplier)))")

        } catch {
            print("[AudioEngineManager] Error abriendo archivo: \(error)")
            delegate?.audioEngineError(error.localizedDescription, code: "FILE_ERROR")
        }
    }

    func pause() {
        // Garantizar ejecución en main thread: el progress timer corre en main y lee
        // isPlaying. Si pause() llega desde el hilo Capacitor (background), existe una
        // ventana ARM64 donde el timer ve isPlaying=true (stale) y publica playbackRate=1.0
        // al lock screen justo antes de que stopProgressTimer() / updateNowPlayingPlaybackState()
        // se ejecuten. Forzar main thread elimina esa race condition por completo.
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.pause() }
            return
        }

        // Siempre actualizar el lock screen al salir, incluso si el guard corta el flujo.
        // Esto cubre el caso donde isPlaying ya es false (p.ej. interrupción previa) pero
        // MPNowPlayingInfoCenter quedó desincronizado.
        defer {
            updateNowPlayingPlaybackState()
            // Safety net: re-asertar estado pausado tras 500ms para atrapar cualquier
            // callback async (artwork download, 300ms re-broadcast, crossfade completion)
            // que pueda reescribir nowPlayingInfo y desincronizar playbackState.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, !self.isPlaying else { return }
                MPNowPlayingInfoCenter.default().playbackState = .paused
                self.localNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
                self.publishNowPlayingInfo()
            }
        }

        guard isPlaying else { return }

        if isStreamMode {
            let time = currentTime()
            streamPlayer?.pause()
            isPlaying = false
            stopAutomixTimer()
            stopProgressTimer()
            notifyPlaybackStateChanged()
            print("[AudioEngineManager] Stream pause en \(String(format: "%.1f", time))s")
            return
        }

        // Capturar posición y sampleTime antes de pausar
        let time = currentTime()
        playStartOffset = time
        // Guardar sampleTime actual para que currentTime() no haga double-counting tras resume
        if let nodeTime = playerA.lastRenderTime,
           nodeTime.isSampleTimeValid,
           let playerTime = playerA.playerTime(forNodeTime: nodeTime) {
            pauseSampleTime = playerTime.sampleTime
        }

        playerA.pause()
        if isCrossfading { playerB.pause() }
        isPlaying = false

        // Suspend automix timer during pause to prevent the trigger from firing
        // while audio is paused. Without this, pausing at 2:02 with trigger at 2:02
        // would fire the crossfade immediately on resume at the wrong moment.
        stopAutomixTimer()

        stopProgressTimer()
        notifyPlaybackStateChanged()

        print("[AudioEngineManager] Pause en \(String(format: "%.1f", time))s")
    }

    func resume() {
        // Mismo motivo que pause(): forzar main thread para evitar race con el progress timer.
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.resume() }
            return
        }

        guard !isPlaying else { return }

        // Cold-start: no file/stream loaded. Ask delegate to reload the current song.
        if currentFile == nil && streamPlayer == nil {
            print("[AudioEngineManager] resume() — no file loaded, requesting reload from delegate")
            delegate?.audioEngineNeedsReload()
            return
        }

        if isStreamMode {
            streamPlayer?.play()
            isPlaying = true
            if automixTriggerTime != nil && !isCrossfading {
                startAutomixTimer()
            }
            startProgressTimer()
            updateNowPlayingPlaybackState()
            notifyPlaybackStateChanged()
            print("[AudioEngineManager] Stream resume")
            return
        }

        guard ensureEngineRunning() else {
            print("[AudioEngineManager] resume() abortado: engine no arrancó")
            notifyPlaybackStateChanged(reason: "engine-dead")
            return
        }

        playerA.play()
        if isCrossfading { playerB.play() }
        isPlaying = true

        // Verify the player is actually rendering after resume.
        // After a long interruption (Siri, phone call) the engine may have
        // restarted but the scheduled segment was invalidated. If after 0.5s
        // playerTime still returns nil, ask the delegate to reload the song
        // at the current position (cold restart).
        let resumeOffset = playStartOffset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isPlaying, !self.isStreamMode else { return }
            if let nodeTime = self.playerA.lastRenderTime,
               nodeTime.isSampleTimeValid,
               self.playerA.playerTime(forNodeTime: nodeTime) != nil {
                return // Player is rendering normally
            }
            // Player is not rendering — schedule is dead. Reload.
            print("[AudioEngineManager] resume() — player not rendering after restart, reloading at \(String(format: "%.1f", resumeOffset))s")
            self.isPlaying = false
            self.delegate?.audioEngineNeedsReload()
        }

        // Restart automix timer if we have a pending trigger (was suspended on pause).
        // This ensures the trigger fires at the correct playback position, not immediately.
        if automixTriggerTime != nil && !isCrossfading {
            startAutomixTimer()
        }

        startProgressTimer()
        updateNowPlayingPlaybackState()
        notifyPlaybackStateChanged()

        print("[AudioEngineManager] Resume")
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func seek(to time: Double) {
        // Cancel any in-progress crossfade before seeking.
        // During crossfade, playerA is fading out and playerB is fading in —
        // seeking playerA without cancelling would leave playerB running independently.
        // Uses cancelCrossfade() to ensure ALL cleanup: DSP reset, streamFadeWatchdog,
        // timePitch rates, and stream observer removal.
        if isCrossfading {
            cancelCrossfade()
            playerB.stop()
            print("[AudioEngineManager] seek(): cancelled in-progress crossfade")
        }

        if isStreamMode {
            clearAutomixTrigger()
            lastSeekTime = CFAbsoluteTimeGetCurrent()
            let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 1000)
            streamPlayer?.seek(to: cmTime) { [weak self] _ in
                self?.updateNowPlayingProgress()
                self?.notifyTimeUpdate()
            }
            delegate?.audioEngineDidSeek(to: time)
            print("[AudioEngineManager] Stream seek a \(String(format: "%.1f", time))s")
            return
        }

        guard let file = currentFile else { return }

        // Invalidate old completion handlers (same pattern as play())
        playSequence += 1
        let thisSeq = playSequence

        let wasPlaying = isPlaying
        playerA.stop()
        // Reset DSP delay lines to prevent click/artifact from stale filter state
        dspNodeA.reset()

        // Marcar timestamp de seek para bloquear automix nativo brevemente
        lastSeekTime = CFAbsoluteTimeGetCurrent()

        // Limpiar automix trigger al hacer seek.
        // QueueManager lo recalculará via delegate (audioEngineDidSeek).
        clearAutomixTrigger()

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, time) * sampleRate)
        let totalFrames = file.length
        let framesToPlay = AVAudioFrameCount(max(0, totalFrames - startFrame))

        guard framesToPlay > 0 else {
            // Seek past end of song — treat as song finished
            isPlaying = false
            stopProgressTimer()
            updateNowPlayingPlaybackState()
            delegate?.audioEngineDidFinishSong()
            return
        }

        playStartOffset = time
        pauseSampleTime = 0 // Reset: nuevo segmento, sampleTime empieza desde 0
        postCrossfadeWallTime = 0
        postCrossfadeOffset = 0

        let activePlayer = playerA
        playerA.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { print("[AudioEngineManager] ⚠️ seek completion: self nil"); return }
                guard self.isPlaying else { print("[AudioEngineManager] ⚠️ seek completion: isPlaying=false"); return }
                if self.isCrossfading {
                    print("[AudioEngineManager] ⚠️ seek completion: A ended during crossfade — rushing B to full volume")
                    self.mixerA.outputVolume = 0
                    self.mixerB.outputVolume = self.replayGainMultiplierB
                    return
                }
                guard self.playerA === activePlayer else { print("[AudioEngineManager] ⚠️ seek completion: playerA swapped"); return }
                guard self.playSequence == thisSeq else { print("[AudioEngineManager] ⚠️ seek completion: playSequence mismatch (have \(self.playSequence), expected \(thisSeq))"); return }
                self.isPlaying = false
                self.stopProgressTimer()
                self.updateNowPlayingPlaybackState()
                self.delegate?.audioEngineDidFinishSong()
                print("[AudioEngineManager] Seek track terminado")
            }
        }

        if wasPlaying {
            playerA.play()
            isPlaying = true
        }

        // Actualizar NowPlaying inmediatamente con la nueva posición
        updateNowPlayingProgress()
        notifyTimeUpdate()

        // Notify delegate so QueueManager can re-set the automix trigger
        delegate?.audioEngineDidSeek(to: time)

        print("[AudioEngineManager] Seek a \(String(format: "%.1f", time))s, playSeq=\(thisSeq), frames=\(framesToPlay)")
    }

    func stop() {
        // Cancel any crossfade first (handles executor, stream timer/watchdog, EQ bypass, timePitch)
        if isCrossfading {
            cancelCrossfade()
        } else {
            // Even if not crossfading, clean up any leftover timers/state
            crossfadeExecutor?.cancel()
            crossfadeExecutor = nil
            streamFadeTimer?.cancel()
            streamFadeTimer = nil
            streamFadeWatchdog?.cancel()
            streamFadeWatchdog = nil
        }

        stopStreamPlayer()
        playerA.stop()
        playerB.stop()
        dspNodeA.reset()
        dspNodeB.reset()
        isPlaying = false
        isCrossfading = false
        currentFile = nil
        nextFile = nil
        playStartOffset = 0
        nextStreamURL = nil
        postCrossfadeWallTime = 0
        postCrossfadeOffset = 0

        stopProgressTimer()
        clearNowPlaying()

        print("[AudioEngineManager] Stop")
    }

    // MARK: - Streaming mode (canciones no cacheadas)

    /// Arranca reproducción inmediata via AVPlayer con la URL HTTP remota.
    /// No requiere descarga previa — iOS empieza a reproducir en ~500ms.
    /// Sin crossfade ni EQ (la canción se cachea en background; la próxima vez
    /// usa AVAudioEngine con todas las features).
    func playStreaming(remoteURL: URL, startAt: Double, replayGainMultiplier: Float,
                       duration: Double, title: String?, artist: String?, album: String?) {
        // Detener playback anterior (ambos modos)
        // Use cancelCrossfade() if mid-crossfade to ensure full cleanup
        if isCrossfading {
            cancelCrossfade()
        } else {
            crossfadeExecutor?.cancel()
            crossfadeExecutor = nil
            streamFadeTimer?.cancel()
            streamFadeTimer = nil
            streamFadeWatchdog?.cancel()
            streamFadeWatchdog = nil
        }
        stopStreamPlayer()
        playerA.stop()
        playerB.stop()
        isCrossfading = false
        nextStreamURL = nil
        clearAutomixTrigger()
        cancelNativeNextFallback()

        if let t = title, !t.isEmpty { currentSongTitle = t }
        if let a = artist { currentSongArtist = a }
        if let al = album { currentSongAlbum = al }

        isPlaying = true
        isStreamMode = true
        currentSongDuration = duration
        playStartOffset = startAt
        replayGainMultiplierA = replayGainMultiplier
        pauseSampleTime = 0
        playSequence += 1

        let item = AVPlayerItem(url: remoteURL)
        let player = AVPlayer(playerItem: item)
        // AVPlayer volume es independiente de AVAudioEngine.
        // Aplicar volumen maestro × ReplayGain para consistencia con el modo engine,
        // donde mainMixerNode.outputVolume = volume y mixerA.outputVolume = replayGainMultiplier.
        player.volume = min(1.0, volume * replayGainMultiplier)
        streamPlayer = player

        if startAt > 0 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 1000))
        }
        player.play()

        // Notificar fin de pista
        streamPlayerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isStreamMode else { return }
            self.isPlaying = false
            self.isStreamMode = false
            self.stopProgressTimer()
            self.updateNowPlayingPlaybackState()
            self.delegate?.audioEngineDidFinishSong()
            print("[AudioEngineManager] Stream track terminado")
        }

        startProgressTimer()
        // Actualizar NowPlaying con la nueva canción
        updateNowPlayingMetadata(title: title ?? "", artist: artist ?? "", album: album ?? "",
                                 duration: duration, artworkUrl: nil)
        updateNowPlayingPlaybackState()
        print("[AudioEngineManager] playStreaming: \(title ?? songIdFromURL(remoteURL))")
    }

    private func stopStreamPlayer() {
        if let observer = streamPlayerEndObserver {
            NotificationCenter.default.removeObserver(observer)
            streamPlayerEndObserver = nil
        }
        streamPlayer?.pause()
        streamPlayer = nil
        isStreamMode = false
    }

    /// Traspasa la reproducción de AVPlayer → AVAudioEngine cuando la descarga completa,
    /// reanudando en la posición actual. Preserva automixTrigger y nextFile intactos
    /// para que el crossfade funcione normalmente tras el handoff.
    func handoffStreamToEngine(fileURL: URL) {
        guard isStreamMode, isPlaying, !isCrossfading else { return }

        // Validate the file BEFORE stopping the stream player.
        // If AVAudioFile can't parse the format (e.g. certain MP3 VBR headers),
        // we stay in stream mode so the song keeps playing via AVPlayer.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            print("[AudioEngineManager] handoffStreamToEngine: archivo incompatible con AVAudioFile, manteniendo stream mode — \(error.localizedDescription)")
            return
        }

        // Capture position from AVPlayer WHILE it's still playing
        let currentPos = currentTime()
        playSequence += 1
        let thisPlaySeq = playSequence

        // ═══ GAPLESS HANDOFF ═══
        // Old order: stop AVPlayer → start engine → gap (~5-20ms, audible)
        // New order: start engine → stop AVPlayer → overlap (~5ms, inaudible)
        //
        // Prepare and start AVAudioEngine BEFORE stopping AVPlayer.
        // Both outputs overlap for ~1 render buffer (~5ms) playing the same
        // audio at the same position — inaudible. A gap is audible.

        guard ensureEngineRunning() else {
            print("[AudioEngineManager] handoffStreamToEngine: engine no arrancó")
            return
        }

        currentFile = file

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, currentPos) * sampleRate)
        let totalFrames = file.length
        let framesToPlay = AVAudioFrameCount(max(0, totalFrames - startFrame))

        guard framesToPlay > 0 else {
            print("[AudioEngineManager] handoffStreamToEngine: sin frames en \(String(format: "%.1f", currentPos))s")
            return
        }

        mixerA.outputVolume = replayGainMultiplierA
        dspNodeA.reset()
        dspNodeB.reset()
        mixerA.pan = 0
        mixerB.pan = 0
        engine.mainMixerNode.outputVolume = volume

        playStartOffset = currentPos
        pauseSampleTime = 0

        // Si la duración fue 0 (song.duration no disponible en Navidrome),
        // calcularla desde el archivo real ahora que lo tenemos descargado.
        if currentSongDuration <= 0 {
            currentSongDuration = Double(file.length) / file.processingFormat.sampleRate
            print("[AudioEngineManager] handoffStreamToEngine: duración calculada del archivo: \(String(format: "%.1f", currentSongDuration))s")
        }

        let activePlayer = playerA
        playerA.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { print("[AudioEngineManager] ⚠️ handoff completion: self nil"); return }
                guard self.isPlaying else { print("[AudioEngineManager] ⚠️ handoff completion: isPlaying=false"); return }
                if self.isCrossfading {
                    print("[AudioEngineManager] ⚠️ handoff completion: A ended during crossfade — rushing B to full volume")
                    self.mixerA.outputVolume = 0
                    self.mixerB.outputVolume = self.replayGainMultiplierB
                    return
                }
                guard self.playerA === activePlayer else { print("[AudioEngineManager] ⚠️ handoff completion: playerA swapped"); return }
                guard self.playSequence == thisPlaySeq else { print("[AudioEngineManager] ⚠️ handoff completion: playSequence mismatch (have \(self.playSequence), expected \(thisPlaySeq))"); return }
                self.isPlaying = false
                self.stopProgressTimer()
                self.updateNowPlayingPlaybackState()
                self.delegate?.audioEngineDidFinishSong()
                print("[AudioEngineManager] Handoff track terminado")
            }
        }

        // Switch currentTime() to read from the engine BEFORE starting it.
        // Without this, the progress timer could fire during the ~5ms overlap
        // and read the stream player's (stale) position instead of the engine's.
        isStreamMode = false

        // Start AVAudioEngine FIRST — audio begins flowing through the engine
        playerA.play()

        // THEN stop AVPlayer — brief overlap (~5ms) of same audio is inaudible,
        // whereas the old gap (stop first, play after) was audible as a click/cut.
        stopStreamPlayer()

        print("[AudioEngineManager] Handoff stream→engine en \(String(format: "%.1f", currentPos))s (gapless), playSeq=\(thisPlaySeq)")
    }

    private func songIdFromURL(_ url: URL) -> String {
        url.lastPathComponent
    }

    func setVolume(_ vol: Float) {
        volume = max(0, min(1, vol))
        engine.mainMixerNode.outputVolume = volume
        // Modo stream: AVPlayer.volume = volumen × ReplayGain (igual que modo engine)
        streamPlayer?.volume = min(1.0, volume * replayGainMultiplierA)
    }

    // MARK: - Tiempo actual

    func currentTime() -> Double {
        let raw: Double

        // Modo streaming: leer posición directamente del AVPlayer
        if isStreamMode, let player = streamPlayer {
            let t = player.currentTime().seconds
            raw = t.isNaN || t.isInfinite ? playStartOffset : t
        } else if isPlaying,
              let nodeTime = playerA.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerA.playerTime(forNodeTime: nodeTime) {
            // Restar pauseSampleTime para evitar double-counting tras pause/resume.
            // Después de resume, sampleTime continúa desde donde estaba al pausar,
            // pero playStartOffset ya incluye ese tiempo. Solo contar samples nuevos.
            let deltaSamples = playerTime.sampleTime - pauseSampleTime
            raw = playStartOffset + Double(deltaSamples) / playerTime.sampleRate
            // playerTime succeeded — clear wall-clock fallback (no longer needed)
            if postCrossfadeWallTime > 0 { postCrossfadeWallTime = 0 }
        } else if postCrossfadeWallTime > 0 {
            // Wall-clock fallback: playerTime(forNodeTime:) returns nil (broken by
            // AudioUnitReset or DSP disruption), but we know the position at crossfade
            // completion + elapsed wall time. Provides smooth progress until recovery.
            let elapsed = CACurrentMediaTime() - postCrossfadeWallTime
            raw = postCrossfadeOffset + elapsed
        } else {
            raw = playStartOffset
        }

        // Clamp to valid range [0, duration]. Prevents:
        // - Negative values from rounding errors or stale deltaSamples
        // - Overflow past duration during crossfade swap or stream mode fallback
        // - Stale playStartOffset from previous song leaking through guard fallback
        let clamped = max(0, currentSongDuration > 0 ? min(raw, currentSongDuration) : raw)
        return clamped
    }

    // MARK: - Preparar siguiente canción

    /// Almacena la URL de streaming de B inmediatamente cuando JS llama prepareNext.
    /// Permite hacer crossfade en modo stream si el archivo no descarga a tiempo.
    func setNextStreamURL(_ url: URL, replayGainMultiplier: Float) {
        nextStreamURL = url
        replayGainMultiplierB = replayGainMultiplier
    }

    func prepareNext(fileURL: URL, replayGainMultiplier: Float) {
        do {
            let file = try AVAudioFile(forReading: fileURL)
            nextFile = file
            replayGainMultiplierB = replayGainMultiplier
            nextStreamURL = nil // ya tenemos el archivo, el fallback no es necesario
            // Calculate real duration from file frames — overrides metadata if available.
            // This ensures post-crossfade duration is accurate even if Navidrome metadata is wrong.
            let fileDuration = Double(file.length) / file.processingFormat.sampleRate
            if fileDuration > 0 {
                nextSongDuration = fileDuration
            }
            // nextFile ready for crossfade
            print("[AudioEngineManager] Next preparado: \(fileURL.lastPathComponent) (RG: \(String(format: "%.3f", replayGainMultiplier)), dur: \(String(format: "%.1f", nextSongDuration))s)")
        } catch {
            print("[AudioEngineManager] Error preparando next: \(error)")
            delegate?.audioEngineError(error.localizedDescription, code: "FILE_ERROR")
        }
    }

    // MARK: - Crossfade

    /// Resultado de ejecutar crossfade — el plugin lo usa para resolver/rechazar la Promise de JS.
    enum CrossfadeResult {
        case started
        case noNextFile
        case alreadyCrossfading
    }

    @discardableResult
    func executeCrossfade(config: CrossfadeExecutor.Config) -> CrossfadeResult {
        guard let nextFile = nextFile else {
            // Archivo B no listo: usar stream fallback si tenemos la URL.
            // Esto garantiza crossfade aunque la descarga no haya completado.
            if let streamURL = nextStreamURL {
                return executeStreamFallbackCrossfade(streamURL: streamURL, config: config)
            }
            print("[AudioEngineManager] No hay next file ni stream URL para crossfade")
            return .noNextFile
        }
        guard !isCrossfading else {
            print("[AudioEngineManager] Crossfade ya en curso")
            return .alreadyCrossfading
        }

        // Safety net: si el handoff stream→engine no completó todavía (descarga lenta o
        // red inestable), detener AVPlayer y activar el engine aquí mismo.
        // En condiciones normales el handoff ocurre mucho antes del trigger y este bloque
        // no se ejecuta. Resultado: cut-A + fade-in-B en vez de no hacer ninguna transición.
        if isStreamMode {
            print("[AudioEngineManager] executeCrossfade: handoff no completó aún — cut A + fade in B")
            stopStreamPlayer()
            guard ensureEngineRunning() else {
                print("[AudioEngineManager] executeCrossfade: engine no arrancó tras cut streaming")
                return .noNextFile
            }
        }

        isCrossfading = true
        crossfadeStartedAt = CFAbsoluteTimeGetCurrent()
        delegate?.audioEngineCrossfadeStarted()

        let executor = CrossfadeExecutor(
            config: config,
            engine: engine,
            playerA: playerA,
            playerB: playerB,
            dspA: dspNodeA,
            dspB: dspNodeB,
            mixerA: mixerA,
            mixerB: mixerB,
            timePitchA: timePitchA,
            timePitchB: timePitchB,
            currentFile: currentFile,
            nextFile: nextFile,
            maxVolumeA: replayGainMultiplierA,
            maxVolumeB: replayGainMultiplierB,
            getMasterVolume: { [weak self] in self?.volume ?? 1.0 },
            currentTitle: currentSongTitle,
            nextTitle: nextSongTitle
        )

        executor.onComplete = { [weak self] startOffset in
            guard let self = self, self.isCrossfading else {
                // Stale callback — crossfade was cancelled (user skipped) between
                // when completeCrossfade() dispatched this to main and now. The new
                // song is already playing; doing the swap would corrupt state.
                print("[AudioEngineManager] onComplete: discarded (crossfade already cancelled)")
                return
            }

            // Parar playerA (canción saliente, ya silenciado)
            self.playerA.stop()

            // ═══ SWAP: playerB (que está sonando) pasa a ser playerA ═══
            // Intercambiamos las referencias para que pause/resume/seek/currentTime
            // siempre operen sobre el player activo (playerA).
            swap(&self.playerA, &self.playerB)
            swap(&self.dspNodeA, &self.dspNodeB)
            swap(&self.timePitchA, &self.timePitchB)
            swap(&self.mixerA, &self.mixerB)

            // ═══ STEP 1: Compute bPosition WHILE playerA (post-swap) is still active ═══
            // After swap, playerA is the new song's player (was playerB). Read its
            // current position BEFORE stopping it for the DSP restart.
            let bPosition: Double
            if let nodeTime = self.playerA.lastRenderTime,
               nodeTime.isSampleTimeValid,
               let pTime = self.playerA.playerTime(forNodeTime: nodeTime) {
                bPosition = startOffset + Double(pTime.sampleTime) / pTime.sampleRate
            } else {
                bPosition = startOffset
            }

            // ═══ STEP 2: Update file/metadata BEFORE restart ═══
            self.currentFile = nextFile
            self.nextFile = nil
            self.replayGainMultiplierA = self.replayGainMultiplierB

            if self.nextSongDuration > 0 {
                self.currentSongDuration = self.nextSongDuration
            }
            self.currentEffectiveEnd = 0
            if !self.nextSongTitle.isEmpty  { self.currentSongTitle  = self.nextSongTitle }
            if !self.nextSongArtist.isEmpty { self.currentSongArtist = self.nextSongArtist }
            if !self.nextSongAlbum.isEmpty  { self.currentSongAlbum  = self.nextSongAlbum }

            // ═══ STEP 3: DSP RESET — instant, guaranteed ═══
            // With custom BiquadDSPNode, reset() zeroes delay lines and sets
            // coefficients to passthrough. No trampoline, no reconnect needed.
            self.dspNodeA.reset()
            self.dspNodeB.reset()

            // Update playback state (playerA is already playing, just reset DSP)
            self.playStartOffset = bPosition
            self.pauseSampleTime = 0
            self.playSequence += 1

            // Reset stereo pan (post-swap: both must be centered)
            self.mixerA.pan = 0
            self.mixerB.pan = 0

            // Mixer volumes
            self.mixerA.outputVolume = self.replayGainMultiplierA
            self.mixerB.outputVolume = 0
            self.engine.mainMixerNode.outputVolume = self.volume

            // Backstop: single delayed reset to catch any ghost filterTick
            let bsDspA = self.dspNodeA, bsDspB = self.dspNodeB
            let bsMixA = self.mixerA, bsMixB = self.mixerB
            let bsTPa = self.timePitchA
            CrossfadeExecutor.automationQueue.asyncAfter(deadline: .now() + 0.1) {
                bsDspA.reset()
                bsDspB.reset()
                bsMixA.pan = 0
                bsMixB.pan = 0
                CrossfadeExecutor.resetTimePitchSoft(bsTPa)
            }

            // Reset stalled-progress counters
            self.stalledTickCount = 0
            self.lastReportedTime = 0

            // Wall-clock fallback
            self.postCrossfadeWallTime = CACurrentMediaTime()
            self.postCrossfadeOffset = bPosition

            // Grace period for SAFETY NET 2
            self.crossfadeCompletedAt = CFAbsoluteTimeGetCurrent()

            self.isCrossfading = false
            self.crossfadeExecutor = nil

            // Reset consumed "next song" metadata to prevent stale values
            // from leaking into the NEXT crossfade cycle
            self.nextSongTitle = ""
            self.nextSongArtist = ""
            self.nextSongAlbum = ""
            self.nextSongDuration = 0
            self.nextStreamURL = nil

            // Ahora sí actualizar NowPlaying con la duración de song B (crossfade terminó)
            self.localNowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = self.currentSongDuration
            self.updateNowPlayingPlaybackState()
            // Enviar la posición ACTUAL del nuevo player (no startOffset, que es donde
            // B empezó al inicio del crossfade). Tras el swap, currentTime() lee del
            // nuevo playerA y refleja startOffset + tiempo transcurrido del crossfade.
            let actualPosition = self.currentTime()
            self.delegate?.audioEngineCrossfadeCompleted(startOffset: actualPosition)

            print("[AudioEngineManager] Crossfade completado (swap A↔B), offset: \(String(format: "%.1f", actualPosition))s, duration: \(String(format: "%.1f", self.currentSongDuration))s")
        }

        // Safety net: si playerB llega al final de su buffer sin que el crossfade haya
        // completado (automix no disparó a tiempo, watchdog falló), notificar onTrackEnd
        // para que JS pueda recuperar el flujo con una transición directa.
        executor.onPlayerBEndedNaturally = { [weak self] in
            guard let self = self, self.isCrossfading else { return }
            print("[AudioEngineManager] ⚠️ PlayerB terminó sin crossfade completado — disparando onTrackEnd")
            // Cancel executor timers BEFORE releasing it — prevents ghost filterTicks
            self.crossfadeExecutor?.cancel()
            self.isCrossfading = false
            self.crossfadeExecutor = nil
            // Promover B→A manualmente para que el estado quede consistente
            self.playerA.stop()
            swap(&self.playerA, &self.playerB)
            swap(&self.dspNodeA, &self.dspNodeB)
            swap(&self.timePitchA, &self.timePitchB)
            swap(&self.mixerA, &self.mixerB)
            // ═══ DSP RESET: instant via BiquadDSPNode ═══
            self.dspNodeA.reset()
            self.dspNodeB.reset()
            self.mixerA.pan = 0
            self.mixerB.pan = 0
            self.currentFile = self.nextFile
            self.nextFile = nil
            self.replayGainMultiplierA = self.replayGainMultiplierB
            // Reset time state for the new song — without this, currentTime() returns
            // stale playStartOffset from the old song after the swap.
            self.playStartOffset = 0
            self.pauseSampleTime = 0
            if self.nextSongDuration > 0 { self.currentSongDuration = self.nextSongDuration }
            if !self.nextSongTitle.isEmpty  { self.currentSongTitle  = self.nextSongTitle }
            if !self.nextSongArtist.isEmpty { self.currentSongArtist = self.nextSongArtist }
            if !self.nextSongAlbum.isEmpty  { self.currentSongAlbum  = self.nextSongAlbum }
            self.isPlaying = false
            self.stopProgressTimer()
            self.updateNowPlayingPlaybackState()
            self.delegate?.audioEngineDidFinishSong()
        }

        // Reset idle chain B before crossfade — instant with BiquadDSPNode
        dspNodeB.reset()

        crossfadeExecutor = executor
        executor.start()
        return .started
    }

    func cancelCrossfade() {
        crossfadeExecutor?.cancel()
        crossfadeExecutor = nil
        streamFadeTimer?.cancel()
        streamFadeTimer = nil
        streamFadeWatchdog?.cancel()
        streamFadeWatchdog = nil
        isCrossfading = false
        // ═══ DSP RESET: instant via BiquadDSPNode ═══
        // No trampoline, no reconnect — reset() zeroes coefficients + delay lines.
        dspNodeA.reset()
        dspNodeB.reset()
        playerB.stop()
        // Restore mixer volume (may have been mid-fade)
        mixerA.outputVolume = replayGainMultiplierA
        mixerB.outputVolume = 0
        // Reset stereo pan
        mixerA.pan = 0
        mixerB.pan = 0
        // Backstop on automationQueue: serialize after any in-flight filterTick
        let bsDspA = self.dspNodeA, bsDspB = self.dspNodeB
        let bsMixA = self.mixerA, bsMixB = self.mixerB
        let bsTPa = self.timePitchA
        CrossfadeExecutor.automationQueue.asyncAfter(deadline: .now() + 0.15) {
            bsDspA.reset()
            bsDspB.reset()
            bsMixA.pan = 0
            bsMixB.pan = 0
            CrossfadeExecutor.resetTimePitchSoft(bsTPa)
        }
        stopStreamPlayer()  // Clean up stream observer to prevent stale callbacks
    }

    // MARK: - Stream fallback crossfade (cuando nextFile == nil)

    /// Crossfade usando AVPlayer streaming para B cuando el archivo no descargó a tiempo.
    /// Fade out A via mixerA.outputVolume + fade in B via AVPlayer.volume.
    /// Tras completar, B queda como streamPlayer activo.
    /// handoffStreamToEngine() lo promoverá a AVAudioEngine en cuanto la descarga complete.
    private func executeStreamFallbackCrossfade(streamURL: URL, config: CrossfadeExecutor.Config) -> CrossfadeResult {
        guard !isCrossfading else { return .alreadyCrossfading }

        print("[AudioEngineManager] ⚡ Stream fallback crossfade — archivo B no listo, usando AVPlayer streaming")

        // Si A está en stream mode, cortar y activar el engine para que mixerA.outputVolume funcione
        if isStreamMode {
            let streamPos = currentTime()
            stopStreamPlayer()
            guard ensureEngineRunning() else {
                print("[AudioEngineManager] executeStreamFallbackCrossfade: engine no arrancó")
                return .noNextFile
            }
            playStartOffset = streamPos
            pauseSampleTime = 0
            // No hay frames de A en el engine → mixerA.outputVolume fade-out arranca desde 0 (corte limpio)
        }

        isCrossfading = true
        crossfadeStartedAt = CFAbsoluteTimeGetCurrent()
        delegate?.audioEngineCrossfadeStarted()

        // Calcular startOffset de B (delegando a CrossfadeExecutor para evitar duplicar lógica)
        let startOffset = CrossfadeExecutor.calculateTimings(config: config).startOffset

        // Crear AVPlayer para B y posicionarlo en startOffset
        let item = AVPlayerItem(url: streamURL)
        let bPlayer = AVPlayer(playerItem: item)
        bPlayer.volume = 0
        if startOffset > 0 {
            bPlayer.seek(to: CMTime(seconds: startOffset, preferredTimescale: 1000))
        }
        bPlayer.play()

        // Register end-of-track observer for B immediately (before fade starts).
        // If B is a very short track that ends before the fade completes,
        // this ensures we still detect it and clean up state.
        // Stored in self.streamPlayerEndObserver so the watchdog can reference it via self.
        if let oldObserver = self.streamPlayerEndObserver {
            NotificationCenter.default.removeObserver(oldObserver)
        }
        self.streamPlayerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if self.isCrossfading {
                // B ended during fade — force-complete the crossfade now
                print("[AudioEngineManager] ⚠️ Stream B ended during fade — forcing completion")
                self.streamFadeTimer?.cancel()
                self.streamFadeTimer = nil
                self.streamFadeWatchdog?.cancel()
                self.streamFadeWatchdog = nil
                self.playerA.stop()
                self.mixerA.outputVolume = 0
                // Reset crossfade EQ + pan to neutral
                self.dspNodeA.reset()
                self.dspNodeB.reset()
                self.mixerA.pan = 0
                self.mixerB.pan = 0
                self.isCrossfading = false
                self.crossfadeExecutor = nil
                self.nextStreamURL = nil
                // B already finished — no stream player to keep
                if let obs = self.streamPlayerEndObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.streamPlayerEndObserver = nil
                }
                self.streamPlayer = nil
                self.isStreamMode = false
                self.isPlaying = false
                self.playStartOffset = startOffset
                self.replayGainMultiplierA = self.replayGainMultiplierB
                if self.nextSongDuration > 0 { self.currentSongDuration = self.nextSongDuration }
                if !self.nextSongTitle.isEmpty  { self.currentSongTitle  = self.nextSongTitle }
                if !self.nextSongArtist.isEmpty { self.currentSongArtist = self.nextSongArtist }
                if !self.nextSongAlbum.isEmpty  { self.currentSongAlbum  = self.nextSongAlbum }
                self.stopProgressTimer()
                self.updateNowPlayingPlaybackState()
                self.delegate?.audioEngineDidFinishSong()
            } else if self.isStreamMode {
                // Normal end-of-track after crossfade completed
                self.isPlaying = false
                self.isStreamMode = false
                self.stopProgressTimer()
                self.updateNowPlayingPlaybackState()
                self.delegate?.audioEngineDidFinishSong()
                print("[AudioEngineManager] Stream fallback: track B terminado")
            }
        }

        let fadeDuration = config.fadeDuration * 1.3  // igual que CrossfadeExecutor.fadeOutDuration
        let startTime = CACurrentMediaTime()
        let endTime = startTime + fadeDuration
        let capturedMaxA = replayGainMultiplierA
        let capturedMaxB = replayGainMultiplierB

        // Watchdog: force-complete if fade takes too long (iOS suspension, etc.)
        // Uses a dedicated queue to avoid .main throttling in background/CarPlay.
        let watchdog = DispatchSource.makeTimerSource(queue: CrossfadeExecutor.automationQueue)
        let watchdogTimeout = fadeDuration + 5.0
        watchdog.schedule(deadline: .now() + watchdogTimeout, leeway: .milliseconds(500))
        watchdog.setEventHandler { [weak self] in
            guard let self = self, self.isCrossfading else { return }
            print("[AudioEngineManager] ⚠️ Stream fallback watchdog — forcing completion after \(String(format: "%.1f", watchdogTimeout))s")
            self.streamFadeTimer?.cancel()
            self.streamFadeTimer = nil
            self.streamFadeWatchdog?.cancel()
            self.streamFadeWatchdog = nil
            // Force to the completed state
            self.mixerA.outputVolume = 0
            bPlayer.volume = min(1.0, self.volume * capturedMaxB)
            self.playerA.stop()
            // Reset crossfade DSP + pan to neutral
            self.dspNodeA.reset()
            self.dspNodeB.reset()
            self.mixerA.pan = 0
            self.mixerB.pan = 0
            // Observer is already in self.streamPlayerEndObserver — just assign the player
            self.streamPlayer = bPlayer
            self.isStreamMode = true
            self.isPlaying = true
            self.isCrossfading = false
            self.crossfadeExecutor = nil
            self.nextStreamURL = nil
            self.playStartOffset = startOffset
            self.replayGainMultiplierA = capturedMaxB
            if self.nextSongDuration > 0 { self.currentSongDuration = self.nextSongDuration }
            if !self.nextSongTitle.isEmpty  { self.currentSongTitle  = self.nextSongTitle }
            if !self.nextSongArtist.isEmpty { self.currentSongArtist = self.nextSongArtist }
            if !self.nextSongAlbum.isEmpty  { self.currentSongAlbum  = self.nextSongAlbum }
            self.startProgressTimer()
            self.updateNowPlayingPlaybackState()
            self.delegate?.audioEngineCrossfadeCompleted(startOffset: self.currentTime())
        }
        streamFadeWatchdog = watchdog
        watchdog.resume()

        let timer = DispatchSource.makeTimerSource(queue: CrossfadeExecutor.automationQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isCrossfading else {
                self?.streamFadeTimer?.cancel()
                self?.streamFadeTimer = nil
                return
            }

            let t = CACurrentMediaTime()
            let progress = min(1.0, (t - startTime) / fadeDuration)

            // A: fade out via engine mixer
            self.mixerA.outputVolume = capturedMaxA * Float(max(0.0, 1.0 - progress))
            // B: fade in via AVPlayer volume
            bPlayer.volume = min(1.0, self.volume * capturedMaxB * Float(progress))

            guard t >= endTime else { return }

            // ─── Crossfade completado ───
            self.streamFadeTimer?.cancel()
            self.streamFadeTimer = nil
            self.streamFadeWatchdog?.cancel()
            self.streamFadeWatchdog = nil

            self.mixerA.outputVolume = 0
            bPlayer.volume = min(1.0, self.volume * capturedMaxB)
            self.playerA.stop()
            // Reset crossfade DSP + pan to neutral
            self.dspNodeA.reset()
            self.dspNodeB.reset()
            self.mixerA.pan = 0
            self.mixerB.pan = 0

            // B pasa a ser el stream player activo
            // Observer is already in self.streamPlayerEndObserver (registered before fade started)
            self.streamPlayer = bPlayer
            self.isStreamMode = true
            self.isPlaying = true
            self.isCrossfading = false
            self.crossfadeExecutor = nil
            self.nextStreamURL = nil
            self.playStartOffset = startOffset
            self.replayGainMultiplierA = capturedMaxB

            // Actualizar metadata de la nueva canción
            if self.nextSongDuration > 0 { self.currentSongDuration = self.nextSongDuration }
            if !self.nextSongTitle.isEmpty  { self.currentSongTitle  = self.nextSongTitle }
            if !self.nextSongArtist.isEmpty { self.currentSongArtist = self.nextSongArtist }
            if !self.nextSongAlbum.isEmpty  { self.currentSongAlbum  = self.nextSongAlbum }

            // Re-iniciar progress timer para B
            self.startProgressTimer()

            // Actualizar NowPlaying
            self.updateNowPlayingMetadata(
                title: self.currentSongTitle,
                artist: self.currentSongArtist,
                album: self.currentSongAlbum,
                duration: self.currentSongDuration,
                artworkUrl: nil
            )
            self.updateNowPlayingPlaybackState()

            let actualPosition = self.currentTime()
            self.delegate?.audioEngineCrossfadeCompleted(startOffset: actualPosition)

            print("[AudioEngineManager] Stream fallback crossfade completado en \(String(format: "%.1f", actualPosition))s")
        }

        streamFadeTimer = timer
        timer.resume()

        return .started
    }

    // MARK: - ReplayGain

    static func computeReplayGainMultiplier(gainDb: Double, trackPeak: Double) -> Float {
        let defaultDb = -8.0
        let db = gainDb.isNaN ? defaultDb : gainDb
        var multiplier = pow(10.0, db / 20.0)
        if trackPeak > 0 {
            let maxMult = 0.99 / trackPeak
            multiplier = min(multiplier, maxMult)
        }
        return Float(multiplier)
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        // Timer.scheduledTimer se añade al RunLoop del hilo actual.
        // Capacitor llama resume/play desde hilos de trabajo cuyo RunLoop
        // no procesa timers → forzar siempre al main RunLoop.
        let start = { [weak self] in
            guard let self = self else { return }
            self.stopProgressTimer()
            self.stalledTickCount = 0
            self.lastReportedTime = 0
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: self.progressInterval, repeats: true) { [weak self] _ in
                guard let self = self, self.isPlaying else { return }
                self.updateNowPlayingProgress()
                self.notifyTimeUpdate()
            }
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
    }

    private func stopProgressTimer() {
        // invalidate() debe llamarse desde el mismo hilo donde se creó el timer (main)
        let stop = { [weak self] in
            self?.progressTimer?.invalidate()
            self?.progressTimer = nil
        }
        if Thread.isMainThread { stop() } else { DispatchQueue.main.async(execute: stop) }
    }

    private func notifyTimeUpdate() {
        // En modo stream, si la duración es 0 (song.duration no disponible en Navidrome),
        // intentar leerla del AVPlayerItem cuando el ítem esté listo para reproducir.
        // AVPlayerItem.duration solo es válido una vez status == .readyToPlay.
        if isStreamMode, currentSongDuration <= 0,
           let item = streamPlayer?.currentItem,
           item.status == .readyToPlay {
            let d = item.duration.seconds
            if d.isFinite && !d.isNaN && d > 0 {
                currentSongDuration = d
                localNowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = d
                MPNowPlayingInfoCenter.default().nowPlayingInfo = localNowPlayingInfo
                print("[AudioEngineManager] Duración obtenida de AVPlayerItem: \(String(format: "%.1f", d))s")
            }
        }

        let rawTime = currentTime()
        // Clamp time to valid range — prevents negative values and overflow past duration
        // which can happen briefly during crossfade player swap
        let time = max(0, currentSongDuration > 0 ? min(rawTime, currentSongDuration) : rawTime)
        delegate?.audioEngineProgressUpdate(current: time, duration: currentSongDuration)

        // SAFETY NET 1: if we're in the last 1.5s of the song (or past it) and there's no
        // automix trigger set and no crossfade happening, force advance to next song.
        // This catches cases where:
        // - prepareNextForCrossfade async task failed/timed out
        // - setAutomixTrigger was never called
        // - completion handler didn't fire (stream mode edge cases)
        // - crossfade completed but the segment's completion handler was invalidated
        if currentSongDuration > 0 && rawTime > 0 && !isCrossfading && automixTriggerTime == nil {
            let remaining = currentSongDuration - rawTime
            if remaining < 1.5 && isPlaying {
                print("[AudioEngineManager] ⚠️ SAFETY NET: song ending/ended (remaining=\(String(format: "%.1f", remaining))s) with no automix trigger — forcing advance")
                isPlaying = false
                stopProgressTimer()
                stopStreamPlayer()
                playerA.stop()
                updateNowPlayingPlaybackState()
                delegate?.audioEngineDidFinishSong()
            }
        }

        // SAFETY NET 2: detect stalled playback — progress not advancing for 3+ seconds
        // while isPlaying is true. This catches post-crossfade stalls where:
        // - The new playerA's segment ended but the completion handler was discarded
        //   (CrossfadeExecutor cancelled, playSequence incremented)
        // - currentSongDuration is 0 so SAFETY NET 1 can't fire
        // - Any other case where the engine thinks it's playing but audio stopped
        if isPlaying && !isCrossfading && rawTime > 0 {
            // Grace period: skip stalled-progress detection for 5s after crossfade.
            // playerTime(forNodeTime:) may return nil briefly after the swap/DSP reset,
            // causing currentTime() to use the wall-clock fallback. During this window
            // the stall detector must not fire.
            let timeSinceCrossfade = CFAbsoluteTimeGetCurrent() - crossfadeCompletedAt
            if crossfadeCompletedAt > 0 && timeSinceCrossfade < 5.0 {
                stalledTickCount = 0
                lastReportedTime = rawTime
            } else if abs(rawTime - lastReportedTime) < 0.01 {
                // Time hasn't changed since last tick
                stalledTickCount += 1
                // 3s / 0.25s (progressInterval) = 12 ticks
                if stalledTickCount >= 12 {
                    print("[AudioEngineManager] ⚠️ SAFETY NET 2: progress stalled at \(String(format: "%.1f", rawTime))s for \(stalledTickCount) ticks — forcing advance")
                    stalledTickCount = 0
                    isPlaying = false
                    stopProgressTimer()
                    stopStreamPlayer()
                    playerA.stop()
                    updateNowPlayingPlaybackState()
                    delegate?.audioEngineDidFinishSong()
                }
            } else {
                stalledTickCount = 0
            }
            lastReportedTime = rawTime
        } else {
            stalledTickCount = 0
            lastReportedTime = rawTime
        }

        // SAFETY NET 3: if crossfade has been "in progress" for > 30s, it's stuck.
        // Cancel it and force advance.
        if isCrossfading && crossfadeStartedAt > 0 {
            let elapsed = CFAbsoluteTimeGetCurrent() - crossfadeStartedAt
            if elapsed > 30 {
                print("[AudioEngineManager] ⚠️ SAFETY NET: crossfade stuck for \(String(format: "%.0f", elapsed))s — cancelling and advancing")
                cancelCrossfade()
                isPlaying = false
                stopProgressTimer()
                updateNowPlayingPlaybackState()
                delegate?.audioEngineDidFinishSong()
            }
        }
    }

    // MARK: - Native Automix Timer (background-safe)

    /// JS llama esto con el trigger time calculado por DJMixingAlgorithms.
    /// Si JS se congela (background), el timer nativo dispara el crossfade autónomamente.
    func setAutomixTrigger(triggerTime: Double, config: CrossfadeExecutor.Config) {
        automixTriggerTime = triggerTime
        pendingCrossfadeConfig = config
        startAutomixTimer()
        print("[AudioEngineManager] ✅ Automix trigger SET at \(String(format: "%.1f", triggerTime))s, nextFile=\(nextFile != nil), nextStreamURL=\(nextStreamURL != nil)")
    }

    /// Almacena metadata de la siguiente canción para NowPlaying en background.
    func setNextSongMetadata(title: String, artist: String, album: String, duration: Double) {
        nextSongTitle = title
        nextSongArtist = artist
        nextSongAlbum = album
        nextSongDuration = duration
    }

    /// Set effective end from analysis data. Called by QueueManager when analysis is available.
    func setCurrentEffectiveEnd(_ time: Double) {
        currentEffectiveEnd = time
    }

    func clearAutomixTrigger() {
        automixTriggerTime = nil
        pendingCrossfadeConfig = nil
        stopAutomixTimer()
    }

    private func startAutomixTimer() {
        stopAutomixTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Verificar cada 500ms — suficiente precisión para trigger, el crossfade real es sample-accurate
        timer.schedule(deadline: .now() + 0.5, repeating: .milliseconds(500), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.checkAutomixTrigger()
        }
        automixTimer = timer
        timer.resume()
    }

    private func stopAutomixTimer() {
        automixTimer?.cancel()
        automixTimer = nil
    }

    private var lastAutomixDebugLog: Date = .distantPast

    private func checkAutomixTrigger() {
        // Log guard failures every 5 seconds for diagnostics
        let now = Date()
        let shouldLog = now.timeIntervalSince(lastAutomixDebugLog) >= 5.0

        guard isPlaying else {
            if shouldLog { lastAutomixDebugLog = now; print("[Automix] guard fail: isPlaying=false") }
            return
        }
        guard !isCrossfading else {
            if shouldLog { lastAutomixDebugLog = now; print("[Automix] guard fail: isCrossfading=true") }
            return
        }
        guard let triggerTime = automixTriggerTime else {
            if shouldLog { lastAutomixDebugLog = now; print("[Automix] guard fail: automixTriggerTime=nil") }
            return
        }
        guard let config = pendingCrossfadeConfig else {
            if shouldLog { lastAutomixDebugLog = now; print("[Automix] guard fail: pendingCrossfadeConfig=nil") }
            return
        }
        guard nextFile != nil || nextStreamURL != nil else {
            if shouldLog { lastAutomixDebugLog = now; print("[Automix] guard fail: nextFile=nil AND nextStreamURL=nil, trigger=\(String(format: "%.1f", triggerTime))s") }
            // SAFETY NET: if we're well past the trigger and still no next song prepared,
            // clear the trigger and let the song end naturally (didFinishSong will advance)
            let time = currentTime()
            if time > triggerTime + 5 {
                print("[Automix] ⚠️ SAFETY NET: 5s past trigger with no next prepared — clearing trigger, will advance via didFinishSong")
                automixTriggerTime = nil
                pendingCrossfadeConfig = nil
                stopAutomixTimer()
            }
            return
        }

        // Bloquear automix durante 2s después de un seek manual.
        let timeSinceSeek = CFAbsoluteTimeGetCurrent() - lastSeekTime
        guard timeSinceSeek > 2.0 else {
            if shouldLog { lastAutomixDebugLog = now; print("[Automix] blocked by seek cooldown (\(String(format: "%.1f", timeSinceSeek))s < 2.0)") }
            return
        }

        let time = currentTime()
        if shouldLog {
            lastAutomixDebugLog = now
            print("[Automix] checking: time=\(String(format: "%.1f", time))s / trigger=\(String(format: "%.1f", triggerTime))s (stream=\(isStreamMode))")
        }
        if time >= triggerTime {
            print("[AudioEngineManager] Native automix trigger at \(String(format: "%.1f", time))s (trigger was \(String(format: "%.1f", triggerTime))s)")
            automixTriggerTime = nil
            pendingCrossfadeConfig = nil
            stopAutomixTimer()

            // Ejecutar crossfade de forma autónoma
            let result = executeCrossfade(config: config)
            if result == .started {
                // Actualizar NowPlaying con metadata de la siguiente canción,
                // PERO mantener la duración de song A para que la barra de progreso
                // no salte. La duración de song B se actualiza en onComplete del crossfade.
                if !nextSongTitle.isEmpty {
                    updateNowPlayingMetadata(
                        title: nextSongTitle,
                        artist: nextSongArtist,
                        album: nextSongAlbum,
                        duration: currentSongDuration,  // keep song A's duration during crossfade
                        artworkUrl: nil
                    )
                }
                delegate?.audioEngineCrossfadeStarted()
            } else {
                // SAFETY NET: crossfade failed (no next file, no stream URL, etc.)
                // Don't leave the user stuck — the song will end naturally and
                // audioEngineDidFinishSong will advance to the next track via hard cut.
                print("[AudioEngineManager] ⚠️ Automix crossfade failed (\(result)), song will advance via hard cut at end")
            }
        }
    }

    // MARK: - Native Next Fallback (when JS is frozen)

    /// Reproduce el nextFile directamente como hard cut (sin crossfade).
    /// Usado cuando el usuario toca "next" en lock screen y JS no puede responder.
    func playNextDirectly() {
        guard let nextFile = nextFile else { return }

        // Invalidate old completion handlers
        playSequence += 1
        let thisSeq = playSequence

        // Parar canción actual
        playerA.stop()

        // Transferir nextFile como currentFile
        currentFile = nextFile
        self.nextFile = nil
        // Prefer actual file duration over metadata (same as play())
        let nextFileDuration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
        currentSongDuration = nextFileDuration > 0 ? nextFileDuration : (nextSongDuration > 0 ? nextSongDuration : 0)
        currentSongTitle = nextSongTitle
        currentSongArtist = nextSongArtist
        currentSongAlbum = nextSongAlbum
        replayGainMultiplierA = replayGainMultiplierB
        playStartOffset = 0
        pauseSampleTime = 0

        mixerA.outputVolume = replayGainMultiplierA

        let totalFrames = nextFile.length
        guard totalFrames > 0 else { return }

        let activePlayer = playerA
        playerA.scheduleSegment(nextFile, startingFrame: 0, frameCount: AVAudioFrameCount(totalFrames), at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.isPlaying, !self.isCrossfading,
                      self.playerA === activePlayer, self.playSequence == thisSeq else { return }
                self.isPlaying = false
                self.stopProgressTimer()
                self.updateNowPlayingPlaybackState()
                self.delegate?.audioEngineDidFinishSong()
            }
        }

        playerA.play()
        isPlaying = true

        // Limpiar automix trigger del track anterior
        clearAutomixTrigger()

        startProgressTimer()
        updateNowPlayingMetadata(title: nextSongTitle, artist: nextSongArtist, album: nextSongAlbum, duration: currentSongDuration, artworkUrl: nil)
        updateNowPlayingPlaybackState()

        delegate?.audioEngineNativeNext(title: currentSongTitle, artist: currentSongArtist,
                                        album: currentSongAlbum, duration: currentSongDuration)

        print("[AudioEngineManager] Native next: \(currentSongTitle)")
    }

    /// Devuelve el estado actual completo para reconciliación tras background
    func getFullState() -> [String: Any] {
        return [
            "isPlaying": isPlaying,
            "currentTime": currentTime(),
            "duration": currentSongDuration,
            "isCrossfading": isCrossfading,
            "title": currentSongTitle,
            "artist": currentSongArtist,
            "album": currentSongAlbum,
        ]
    }

    private func notifyPlaybackStateChanged(reason: String? = nil) {
        delegate?.audioEnginePlaybackStateChanged(isPlaying: isPlaying, currentTime: currentTime())
    }

    // MARK: - NowPlaying (directo, sin JS)

    func updateNowPlayingMetadata(title: String, artist: String, album: String, duration: Double, artworkUrl: String?) {
        let update = { [weak self] in
            guard let self = self else { return }
            self.currentSongTitle = title
            self.currentSongArtist = artist
            self.currentSongAlbum = album
            // Only update duration if the new value is valid — passing 0 kills
            // the safety net (guard currentSongDuration > 0) and progress timer,
            // leaving playback stuck with no recovery after crossfade.
            if duration > 0 {
                self.currentSongDuration = duration
            }

            self.localNowPlayingInfo[MPMediaItemPropertyTitle] = title
            self.localNowPlayingInfo[MPMediaItemPropertyArtist] = artist
            self.localNowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
            self.localNowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
            self.localNowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = self.currentTime()
            self.localNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = self.isPlaying ? 1.0 : 0.0
            self.localNowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
            self.localNowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false

            self.localNowPlayingInfo[MPMediaItemPropertyAlbumArtist] = artist
            self.localNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueIndex] = 0
            self.localNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueCount] = 1

            self.publishNowPlayingInfo()
            MPNowPlayingInfoCenter.default().playbackState = self.isPlaying ? .playing : .paused

            // Re-broadcast after 300ms to ensure CarPlay catches the update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.publishNowPlayingInfo()
            }

            // Descargar artwork en background
            if let urlStr = artworkUrl, let url = URL(string: urlStr) {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data = data, let image = UIImage(data: data) else { return }
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.localNowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                        self.publishNowPlayingInfo()
                    }
                }.resume()
            }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    private func updateNowPlayingProgress() {
        localNowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime()
        localNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        publishNowPlayingInfo()
    }

    func updateNowPlayingPlaybackState() {
        // MPNowPlayingInfoCenter DEBE actualizarse en el main thread.
        // pause()/resume() pueden ser llamados desde el hilo de Capacitor (background)
        // y si actualizamos desde ahí, iOS puede ignorar el cambio silenciosamente,
        // dejando el lock screen/Dynamic Island desincronizado.
        let update = { [weak self] in
            guard let self = self else { return }
            // Apple requiere que nowPlayingInfo se publique ANTES de playbackState.
            // Si se hace al revés, iOS puede ignorar el cambio de playbackState
            // y el lock screen / Dynamic Island queda desincronizado.
            self.updateNowPlayingProgress()
            let state: MPNowPlayingPlaybackState = self.isPlaying ? .playing : .paused
            MPNowPlayingInfoCenter.default().playbackState = state
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    private func clearNowPlaying() {
        localNowPlayingInfo = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Publica el diccionario local como una escritura atómica al singleton.
    /// Usar siempre en lugar de escribir directamente a MPNowPlayingInfoCenter.
    /// Re-aserta playbackState tras cada escritura para evitar que iOS lo resetee
    /// al procesar cambios en nowPlayingInfo (bug observado en iOS 17/18).
    private func publishNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = localNowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    // MARK: - Remote Command Center

    private func setupCommandCenter() {
        guard !commandCenterReady else { return }
        commandCenterReady = true

        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        // Next/previous: enviar a JS primero. Si JS no responde en 2s
        // (congelado en background), ejecutar nativamente como fallback.
        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.ensureAudioSessionActive()
            // Limpiar automix Y cancelar crossfade en curso INMEDIATAMENTE.
            // Si el automix disparó un crossfade justo antes del tap en "next",
            // cancelCrossfade() lo detiene para que el skip sea instantáneo.
            self.clearAutomixTrigger()
            self.cancelCrossfade()
            // Native path: QueueManager handles skip directly
            Task { @MainActor in QueueManager.shared.skipNext() }
            return .success
        }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.ensureAudioSessionActive()
            // Limpiar automix y cancelar crossfade (igual que next).
            self.clearAutomixTrigger()
            self.cancelCrossfade()
            // Native path: QueueManager handles skip previous (3s restart logic included)
            Task { @MainActor in QueueManager.shared.skipPrevious() }
            return .success
        }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }

        print("[AudioEngineManager] Command Center configurado")
    }

    private func ensureAudioSessionActive() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioEngineManager] Error reactivando AVAudioSession: \(error)")
        }
    }

    /// Fallback timer para "next" desde lock screen cuando JS está congelado.
    /// Si JS responde (llama play/stop/executeCrossfade), el fallback se cancela.
    private var nativeNextFallbackItem: DispatchWorkItem?

    func scheduleNativeNextFallback() {
        // Cancelar cualquier fallback anterior
        nativeNextFallbackItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Si seguimos reproduciendo la misma canción (JS no respondió), hacer next nativo
            if self.isPlaying && self.hasNextFilePrepared && !self.isCrossfading {
                print("[AudioEngineManager] JS no respondió a next en 2s — ejecutando next nativo")
                self.playNextDirectly()
            }
        }
        nativeNextFallbackItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// JS llama esto para cancelar el fallback (indica que respondió al comando)
    func cancelNativeNextFallback() {
        nativeNextFallbackItem?.cancel()
        nativeNextFallbackItem = nil
    }

    // MARK: - Observers (interrupciones y route changes)

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        // Despachar a main thread: las notificaciones de AVAudioSession pueden llegar
        // desde hilos del sistema. Acceder a isPlaying/wasPlayingBeforeInterruption
        // desde un hilo distinto a main causa data races.
        let handle = { [weak self] in
            guard let self = self else { return }
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = self.isPlaying
                if self.isPlaying {
                    self.pause()
                    self.notifyPlaybackStateChanged(reason: "interruption")
                }
                print("[AudioEngineManager] Interrupción comenzada")

            case .ended:
                let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                let shouldResume = options.contains(.shouldResume)

                // Always resume if we were playing before the interruption.
                // Siri "Announce Messages", short phone calls, and navigation prompts
                // often send .ended WITHOUT .shouldResume. Apple Music and Spotify
                // resume regardless — the user expectation is that music comes back.
                if self.wasPlayingBeforeInterruption {
                    self.ensureAudioSessionActive()
                    // Small delay: let the system finish routing audio back to us.
                    // 0.5s covers Siri dismiss animation + CarPlay audio route restore.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self, !self.isPlaying else { return }
                        self.resume()
                        print("[AudioEngineManager] Interrupción terminada — reanudado (shouldResume: \(shouldResume))")
                    }
                } else {
                    print("[AudioEngineManager] Interrupción terminada — sin reanudar (no estaba reproduciendo)")
                }
                self.wasPlayingBeforeInterruption = false

            @unknown default:
                break
            }
        }
        if Thread.isMainThread { handle() } else { DispatchQueue.main.async(execute: handle) }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // Bluetooth/auriculares desconectados → pausar
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isPlaying {
                    self.pause()
                }
                // Prevenir que handleInterruption(.ended) reanude tras route change:
                // en algunos dispositivos iOS envía interruption + routeChange juntos.
                self.wasPlayingBeforeInterruption = false
                self.notifyPlaybackStateChanged(reason: "routeLost")

                // Safety net: re-asertar paused inmediatamente
                guard !self.isPlaying else { return }
                MPNowPlayingInfoCenter.default().playbackState = .paused
                self.updateNowPlayingProgress()
            }
            // Segunda safety net a 500ms: atrapa resets de iOS tras reconfigure de audio route
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, !self.isPlaying else { return }
                self.localNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
                self.publishNowPlayingInfo()
            }
            print("[AudioEngineManager] Ruta perdida — pausado")

        case .newDeviceAvailable:
            reconfigureIOBuffer()
            // Route change during crossfade: the hardware sample rate may have changed
            // (e.g. Bluetooth 16kHz → speaker 48kHz), invalidating biquad coefficients
            // that were computed with the old rate. Cancel to prevent wrong cutoffs.
            if isCrossfading {
                print("[AudioEngineManager] ⚠️ Route change during crossfade — cancelling to prevent stale DSP coefficients")
                DispatchQueue.main.async { [weak self] in
                    self?.cancelCrossfade()
                }
            }
            print("[AudioEngineManager] Nueva ruta de audio detectada")

        default:
            break
        }
    }

    /// Configura IO buffer óptimo según la ruta de audio.
    /// Replica la lógica de AppDelegate.configureIOBufferForRoute().
    private func reconfigureIOBuffer() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs

        var preferredBuffer: TimeInterval = 0.02 // 20ms default

        for output in outputs {
            if output.portType.rawValue == "CarPlay" {
                preferredBuffer = 0.04 // 40ms para CarPlay wireless
                break
            }
        }

        do {
            try session.setPreferredIOBufferDuration(preferredBuffer)
            let actual = session.ioBufferDuration
            print("[AudioEngineManager] IO buffer: \(String(format: "%.1f", actual * 1000))ms (pedido: \(String(format: "%.1f", preferredBuffer * 1000))ms)")
        } catch {
            print("[AudioEngineManager] Error configurando IO buffer: \(error)")
        }
    }

    // MARK: - Acceso a nodos (para CrossfadeExecutor)

    var engineRef: AVAudioEngine { engine }
    var playerARef: AVAudioPlayerNode { playerA }
    var playerBRef: AVAudioPlayerNode { playerB }
    var dspNodeARef: BiquadDSPNode { dspNodeA }
    var dspNodeBRef: BiquadDSPNode { dspNodeB }
    var mixerARef: AVAudioMixerNode { mixerA }
    var mixerBRef: AVAudioMixerNode { mixerB }
    var timePitchARef: AVAudioUnitTimePitch { timePitchA }
    var timePitchBRef: AVAudioUnitTimePitch { timePitchB }
}
