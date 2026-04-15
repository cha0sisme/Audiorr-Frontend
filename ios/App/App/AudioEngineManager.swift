import AVFoundation
import MediaPlayer
import Capacitor

/// Motor de audio nativo basado en AVAudioEngine.
/// Grafo: playerA → eqA → mixerA → mainMixer → output
///        playerB → eqB → mixerB → mainMixer → output
///
/// Gestiona reproducción, NowPlaying, remote commands e interrupciones.
class AudioEngineManager {

    // MARK: - Shared instance (para acceso desde CarPlay)
    static private(set) var shared: AudioEngineManager?

    // MARK: - Engine y nodos

    private let engine = AVAudioEngine()
    // playerA es siempre el "activo" — tras crossfade se swapean con playerB
    private var playerA: AVAudioPlayerNode
    private var playerB: AVAudioPlayerNode
    private var eqA: AVAudioUnitEQ
    private var eqB: AVAudioUnitEQ
    private var mixerA: AVAudioMixerNode
    private var mixerB: AVAudioMixerNode

    // MARK: - Estado

    private(set) var isPlaying = false
    private var volume: Float = 0.75
    private var currentSongDuration: Double = 0
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

    // MARK: - Native Automix (background-safe)
    // Cuando JS está congelado (pantalla bloqueada), este timer nativo
    // verifica la posición y dispara el crossfade autónomamente.

    private var automixTimer: DispatchSourceTimer?
    /// Tiempo en la canción actual donde debe dispararse el crossfade.
    /// nil = no hay automix programado (JS lo gestiona en foreground).
    private var automixTriggerTime: Double?
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

    // MARK: - Progress timer

    private var progressTimer: Timer?
    private let progressInterval: TimeInterval = 0.25 // 4Hz

    // MARK: - Streaming mode (AVPlayer para canciones no cacheadas)
    // Cuando una canción no está en caché, usamos AVPlayer con la URL HTTP directamente
    // para arrancar en ~500ms (como Spotify). La descarga continúa en background para
    // cachear. La próxima vez, AVAudioEngine sirve el archivo local con crossfade completo.

    private var streamPlayer: AVPlayer?
    private var streamPlayerEndObserver: Any?
    private(set) var isStreamMode = false

    // MARK: - Plugin reference (para enviar eventos a JS)

    weak var plugin: CAPPlugin?

    // MARK: - Init

    init() {
        // Crear nodos
        playerA = AVAudioPlayerNode()
        playerB = AVAudioPlayerNode()
        mixerA = AVAudioMixerNode()
        mixerB = AVAudioMixerNode()

        // EQ con 6 bandas: 0-1 reserved for crossfade, 2-5 reserved for global EQ.
        eqA = AVAudioUnitEQ(numberOfBands: 6)
        eqA.bands[0].filterType = .highPass
        eqA.bands[1].filterType = .lowShelf
        for i in 0..<6 { eqA.bands[i].bypass = true }

        eqB = AVAudioUnitEQ(numberOfBands: 6)
        eqB.bands[0].filterType = .highPass
        eqB.bands[1].filterType = .lowShelf
        for i in 0..<6 { eqB.bands[i].bypass = true }

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
        engine.attach(eqA)
        engine.attach(eqB)
        engine.attach(mixerA)
        engine.attach(mixerB)

        let mainMixer = engine.mainMixerNode

        // Conectar grafo A: playerA → eqA → mixerA → mainMixer
        // Usamos el formato del mainMixer para todas las conexiones intermedias.
        // AVAudioMixerNode convierte formatos automáticamente si hay mismatch.
        let format = mainMixer.outputFormat(forBus: 0)

        engine.connect(playerA, to: eqA, format: nil)
        engine.connect(eqA, to: mixerA, format: nil)
        engine.connect(mixerA, to: mainMixer, format: format)

        // Conectar grafo B: playerB → eqB → mixerB → mainMixer
        engine.connect(playerB, to: eqB, format: nil)
        engine.connect(eqB, to: mixerB, format: nil)
        engine.connect(mixerB, to: mainMixer, format: format)

        // Volumen inicial
        mainMixer.outputVolume = volume
        mixerA.outputVolume = 1.0
        mixerB.outputVolume = 0.0 // B silenciado hasta crossfade

        engine.prepare()
        print("[AudioEngineManager] Audio graph configurado")
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
            plugin?.notifyListeners("onError", data: [
                "message": "Engine failed to start: \(error.localizedDescription)",
                "code": "ENGINE_START_ERROR"
            ])
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

        guard ensureEngineRunning() else {
            print("[AudioEngineManager] play() abortado: engine no arrancó")
            return
        }
        cancelNativeNextFallback() // JS respondió
        clearAutomixTrigger()

        // Invalidate any pending completion handlers from the previous song.
        playSequence += 1
        let thisPlaySeq = playSequence

        // Detener reproducción anterior
        playerA.stop()

        do {
            let file = try AVAudioFile(forReading: fileURL)
            currentFile = file
            currentSongDuration = duration > 0 ? duration : Double(file.length) / file.processingFormat.sampleRate
            replayGainMultiplierA = replayGainMultiplier
            playStartOffset = startAt
            pauseSampleTime = 0

            // Aplicar ReplayGain via mixerA
            mixerA.outputVolume = replayGainMultiplier

            // Asegurar EQ A en bypass para bandas de transición (no estamos en crossfade)
            eqA.bands[0].bypass = true
            eqA.bands[1].bypass = true
            
            // Forzar volumen maestro al valor actual del usuario
            engine.mainMixerNode.outputVolume = volume

            // Calcular frame de inicio
            let sampleRate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(startAt * sampleRate)
            let totalFrames = file.length
            let framesToPlay = AVAudioFrameCount(totalFrames - startFrame)

            guard framesToPlay > 0 else {
                print("[AudioEngineManager] No hay frames para reproducir")
                plugin?.notifyListeners("onError", data: [
                    "message": "No frames to play (startFrame=\(startFrame), totalFrames=\(totalFrames))",
                    "code": "NO_FRAMES"
                ])
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
                    guard let self = self,
                          self.isPlaying,
                          !self.isCrossfading,
                          self.playerA === activePlayer, // Solo si sigue siendo el player activo
                          self.playSequence == thisPlaySeq // No hubo otro play() posterior
                    else { return }
                    self.isPlaying = false
                    self.stopProgressTimer()
                    self.updateNowPlayingPlaybackState()
                    self.plugin?.notifyListeners("onTrackEnd", data: [:])
                    print("[AudioEngineManager] Track terminado")
                }
            }

            playerA.play()
            isPlaying = true

            // Validar que el player realmente arrancó tras un breve delay.
            // playerA.play() puede fallar silenciosamente si el engine murió entre
            // ensureEngineRunning() y aquí (race condition con interrupciones).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.isPlaying, self.playerA === activePlayer, self.playSequence == thisPlaySeq else { return }
                if self.playerA.lastRenderTime == nil || !self.engine.isRunning {
                    print("[AudioEngineManager] ⚠️ playerA no está renderizando — reiniciando engine")
                    self.isPlaying = false
                    self.plugin?.notifyListeners("onError", data: [
                        "message": "Player failed to start rendering",
                        "code": "RENDER_FAILED"
                    ])
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
            plugin?.notifyListeners("onError", data: ["message": error.localizedDescription, "code": "FILE_ERROR"])
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
        defer { updateNowPlayingPlaybackState() }

        guard isPlaying else { return }

        if isStreamMode {
            let time = currentTime()
            streamPlayer?.pause()
            isPlaying = false
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

        if isStreamMode {
            streamPlayer?.play()
            isPlaying = true
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

        startProgressTimer()
        updateNowPlayingPlaybackState()
        notifyPlaybackStateChanged()

        print("[AudioEngineManager] Resume")
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func seek(to time: Double) {
        if isStreamMode {
            let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 1000)
            streamPlayer?.seek(to: cmTime) { [weak self] _ in
                self?.updateNowPlayingProgress()
                self?.notifyTimeUpdate()
            }
            print("[AudioEngineManager] Stream seek a \(String(format: "%.1f", time))s")
            return
        }

        guard let file = currentFile else { return }

        // Invalidate old completion handlers (same pattern as play())
        playSequence += 1
        let thisSeq = playSequence

        let wasPlaying = isPlaying
        playerA.stop()

        // Marcar timestamp de seek para bloquear automix nativo brevemente
        lastSeekTime = CFAbsoluteTimeGetCurrent()

        // CRÍTICO: Limpiar automix trigger al hacer seek.
        // JS lo recalculará y re-enviará con la posición correcta.
        // Sin esto, el trigger viejo puede dispararse prematuramente
        // si el seek deja currentTime cerca del triggerTime anterior.
        clearAutomixTrigger()

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, time) * sampleRate)
        let totalFrames = file.length
        let framesToPlay = AVAudioFrameCount(max(0, totalFrames - startFrame))

        guard framesToPlay > 0 else { return }

        playStartOffset = time
        pauseSampleTime = 0 // Reset: nuevo segmento, sampleTime empieza desde 0

        let activePlayer = playerA
        playerA.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.isPlaying, !self.isCrossfading,
                      self.playerA === activePlayer, self.playSequence == thisSeq else { return }
                self.isPlaying = false
                self.stopProgressTimer()
                self.updateNowPlayingPlaybackState()
                self.plugin?.notifyListeners("onTrackEnd", data: [:])
            }
        }

        if wasPlaying {
            playerA.play()
            isPlaying = true
        }

        // Actualizar NowPlaying inmediatamente con la nueva posición
        updateNowPlayingProgress()
        notifyTimeUpdate()

        print("[AudioEngineManager] Seek a \(String(format: "%.1f", time))s")
    }

    func stop() {
        stopStreamPlayer()
        playerA.stop()
        playerB.stop()
        isPlaying = false
        isCrossfading = false
        currentFile = nil
        nextFile = nil
        playStartOffset = 0

        crossfadeExecutor?.cancel()
        crossfadeExecutor = nil
        streamFadeTimer?.cancel()
        streamFadeTimer = nil
        nextStreamURL = nil

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
        stopStreamPlayer()
        playerA.stop()
        playerB.stop()
        isCrossfading = false
        crossfadeExecutor?.cancel()
        crossfadeExecutor = nil
        streamFadeTimer?.cancel()
        streamFadeTimer = nil
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
            self.plugin?.notifyListeners("onTrackEnd", data: [:])
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
        guard isStreamMode, isPlaying else { return }

        let currentPos = currentTime()
        playSequence += 1
        let thisPlaySeq = playSequence

        stopStreamPlayer()   // isStreamMode = false; AVPlayer detenido

        guard ensureEngineRunning() else {
            print("[AudioEngineManager] handoffStreamToEngine: engine no arrancó")
            return
        }

        do {
            let file = try AVAudioFile(forReading: fileURL)
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
            eqA.bands[0].bypass = true
            eqA.bands[1].bypass = true
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
                    guard let self = self,
                          self.isPlaying,
                          !self.isCrossfading,
                          self.playerA === activePlayer,
                          self.playSequence == thisPlaySeq else { return }
                    self.isPlaying = false
                    self.stopProgressTimer()
                    self.updateNowPlayingPlaybackState()
                    self.plugin?.notifyListeners("onTrackEnd", data: [:])
                }
            }

            playerA.play()
            print("[AudioEngineManager] Handoff stream→engine en \(String(format: "%.1f", currentPos))s")
        } catch {
            print("[AudioEngineManager] handoffStreamToEngine error: \(error)")
        }
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
        // Modo streaming: leer posición directamente del AVPlayer
        if isStreamMode, let player = streamPlayer {
            let t = player.currentTime().seconds
            return t.isNaN || t.isInfinite ? playStartOffset : t
        }
        guard isPlaying,
              let nodeTime = playerA.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerA.playerTime(forNodeTime: nodeTime)
        else {
            return playStartOffset
        }
        // Restar pauseSampleTime para evitar double-counting tras pause/resume.
        // Después de resume, sampleTime continúa desde donde estaba al pausar,
        // pero playStartOffset ya incluye ese tiempo. Solo contar samples nuevos.
        let deltaSamples = playerTime.sampleTime - pauseSampleTime
        return playStartOffset + Double(deltaSamples) / playerTime.sampleRate
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
            nextFile = try AVAudioFile(forReading: fileURL)
            replayGainMultiplierB = replayGainMultiplier
            nextStreamURL = nil // ya tenemos el archivo, el fallback no es necesario
            print("[AudioEngineManager] Next preparado: \(fileURL.lastPathComponent) (RG: \(String(format: "%.3f", replayGainMultiplier)))")
        } catch {
            print("[AudioEngineManager] Error preparando next: \(error)")
            plugin?.notifyListeners("onError", data: ["message": error.localizedDescription, "code": "FILE_ERROR"])
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
        plugin?.notifyListeners("onCrossfadeStart", data: [:])

        let executor = CrossfadeExecutor(
            config: config,
            engine: engine,
            playerA: playerA,
            playerB: playerB,
            eqA: eqA,
            eqB: eqB,
            mixerA: mixerA,
            mixerB: mixerB,
            currentFile: currentFile,
            nextFile: nextFile,
            maxVolumeA: replayGainMultiplierA,
            maxVolumeB: replayGainMultiplierB,
            getMasterVolume: { [weak self] in self?.volume ?? 1.0 },
            currentTitle: currentSongTitle,
            nextTitle: "" // Se establece desde JS al llamar executeCrossfade
        )

        executor.onComplete = { [weak self] startOffset in
            guard let self = self else { return }

            // Parar playerA (canción saliente, ya silenciado)
            self.playerA.stop()

            // ═══ SWAP: playerB (que está sonando) pasa a ser playerA ═══
            // Intercambiamos las referencias para que pause/resume/seek/currentTime
            // siempre operen sobre el player activo (playerA).
            swap(&self.playerA, &self.playerB)
            swap(&self.eqA, &self.eqB)
            swap(&self.mixerA, &self.mixerB)

            self.currentFile = nextFile
            self.nextFile = nil
            self.replayGainMultiplierA = self.replayGainMultiplierB
            self.playStartOffset = startOffset
            self.pauseSampleTime = 0

            // CRÍTICO: Actualizar duración y metadata de la nueva canción.
            // Sin esto, notifyTimeUpdate() sigue enviando la duración de la canción
            // saliente, corrompiendo el cálculo del trigger del siguiente crossfade en JS
            // (remaining = wrongDuration - currentTime < 0 → crossfade bloqueado).
            if self.nextSongDuration > 0 {
                self.currentSongDuration = self.nextSongDuration
            }
            if !self.nextSongTitle.isEmpty  { self.currentSongTitle  = self.nextSongTitle }
            if !self.nextSongArtist.isEmpty { self.currentSongArtist = self.nextSongArtist }
            if !self.nextSongAlbum.isEmpty  { self.currentSongAlbum  = self.nextSongAlbum }

            // Resetear EQ a bypass (bandas de crossfade 0-1 tras el swap)
            self.eqA.bands[0].bypass = true
            self.eqA.bands[1].bypass = true
            self.eqB.bands[0].bypass = true
            self.eqB.bands[1].bypass = true
            
            // Resetear mixer volumes
            self.mixerA.outputVolume = self.replayGainMultiplierA
            self.mixerB.outputVolume = 0
            
            // Asegurar que el master mixer tiene el volumen correcto post-crossfade
            self.engine.mainMixerNode.outputVolume = self.volume

            self.isCrossfading = false
            self.crossfadeExecutor = nil

            self.updateNowPlayingPlaybackState()
            // Enviar la posición ACTUAL del nuevo player (no startOffset, que es donde
            // B empezó al inicio del crossfade). Tras el swap, currentTime() lee del
            // nuevo playerA y refleja startOffset + tiempo transcurrido del crossfade.
            let actualPosition = self.currentTime()
            self.plugin?.notifyListeners("onCrossfadeComplete", data: ["startOffset": actualPosition])

            print("[AudioEngineManager] Crossfade completado (swap A↔B), offset: \(String(format: "%.1f", actualPosition))s")
        }

        // Safety net: si playerB llega al final de su buffer sin que el crossfade haya
        // completado (automix no disparó a tiempo, watchdog falló), notificar onTrackEnd
        // para que JS pueda recuperar el flujo con una transición directa.
        executor.onPlayerBEndedNaturally = { [weak self] in
            guard let self = self, self.isCrossfading else { return }
            print("[AudioEngineManager] ⚠️ PlayerB terminó sin crossfade completado — disparando onTrackEnd")
            self.isCrossfading = false
            self.crossfadeExecutor = nil
            // Promover B→A manualmente para que el estado quede consistente
            self.playerA.stop()
            swap(&self.playerA, &self.playerB)
            swap(&self.eqA, &self.eqB)
            swap(&self.mixerA, &self.mixerB)
            self.currentFile = self.nextFile
            self.nextFile = nil
            self.replayGainMultiplierA = self.replayGainMultiplierB
            if self.nextSongDuration > 0 { self.currentSongDuration = self.nextSongDuration }
            if !self.nextSongTitle.isEmpty  { self.currentSongTitle  = self.nextSongTitle }
            if !self.nextSongArtist.isEmpty { self.currentSongArtist = self.nextSongArtist }
            if !self.nextSongAlbum.isEmpty  { self.currentSongAlbum  = self.nextSongAlbum }
            self.isPlaying = false
            self.stopProgressTimer()
            self.updateNowPlayingPlaybackState()
            self.plugin?.notifyListeners("onTrackEnd", data: [:])
        }

        crossfadeExecutor = executor
        executor.start()
        return .started
    }

    func cancelCrossfade() {
        crossfadeExecutor?.cancel()
        crossfadeExecutor = nil
        streamFadeTimer?.cancel()
        streamFadeTimer = nil
        isCrossfading = false
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
        plugin?.notifyListeners("onCrossfadeStart", data: [:])

        // Calcular startOffset de B (mismo algoritmo que CrossfadeExecutor.calculateTimings)
        let startOffset: Double
        if config.needsAnticipation {
            startOffset = max(0, config.entryPoint - config.fadeDuration - config.anticipationTime)
        } else {
            startOffset = max(0, config.entryPoint - config.fadeDuration)
        }

        // Crear AVPlayer para B y posicionarlo en startOffset
        let item = AVPlayerItem(url: streamURL)
        let bPlayer = AVPlayer(playerItem: item)
        bPlayer.volume = 0
        if startOffset > 0 {
            bPlayer.seek(to: CMTime(seconds: startOffset, preferredTimescale: 1000))
        }
        bPlayer.play()

        let fadeDuration = config.fadeDuration * 1.3  // igual que CrossfadeExecutor.fadeOutDuration
        let startTime = CACurrentMediaTime()
        let endTime = startTime + fadeDuration
        let capturedMaxA = replayGainMultiplierA
        let capturedMaxB = replayGainMultiplierB

        let timer = DispatchSource.makeTimerSource(queue: .main)
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

            self.mixerA.outputVolume = 0
            bPlayer.volume = min(1.0, self.volume * capturedMaxB)
            self.playerA.stop()

            // B pasa a ser el stream player activo
            self.stopStreamPlayer()   // limpia observers anteriores
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

            // Observer de fin de pista para B
            self.streamPlayerEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                guard let self = self, self.isStreamMode else { return }
                self.isPlaying = false
                self.isStreamMode = false
                self.stopProgressTimer()
                self.updateNowPlayingPlaybackState()
                self.plugin?.notifyListeners("onTrackEnd", data: [:])
                print("[AudioEngineManager] Stream fallback: track B terminado")
            }

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

            // Notificar a JS
            let actualPosition = self.currentTime()
            self.plugin?.notifyListeners("onCrossfadeComplete", data: ["startOffset": actualPosition])

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

        let time = currentTime()
        plugin?.notifyListeners("onTimeUpdate", data: [
            "currentTime": time,
            "duration": currentSongDuration,
            "isPlaying": isPlaying,
        ])
    }

    // MARK: - Native Automix Timer (background-safe)

    /// JS llama esto con el trigger time calculado por DJMixingAlgorithms.
    /// Si JS se congela (background), el timer nativo dispara el crossfade autónomamente.
    func setAutomixTrigger(triggerTime: Double, config: CrossfadeExecutor.Config) {
        automixTriggerTime = triggerTime
        pendingCrossfadeConfig = config
        startAutomixTimer()
    }

    /// Almacena metadata de la siguiente canción para NowPlaying en background.
    func setNextSongMetadata(title: String, artist: String, album: String, duration: Double) {
        nextSongTitle = title
        nextSongArtist = artist
        nextSongAlbum = album
        nextSongDuration = duration
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

    private func checkAutomixTrigger() {
        guard isPlaying,
              !isCrossfading,
              let triggerTime = automixTriggerTime,
              let config = pendingCrossfadeConfig,
              nextFile != nil
        else { return }

        // Bloquear automix durante 2s después de un seek manual.
        // Esto da tiempo a JS para recalcular y re-enviar el trigger correcto.
        let timeSinceSeek = CFAbsoluteTimeGetCurrent() - lastSeekTime
        guard timeSinceSeek > 2.0 else { return }

        let time = currentTime()
        if time >= triggerTime {
            print("[AudioEngineManager] Native automix trigger at \(String(format: "%.1f", time))s (trigger was \(String(format: "%.1f", triggerTime))s)")
            automixTriggerTime = nil
            pendingCrossfadeConfig = nil
            stopAutomixTimer()

            // Ejecutar crossfade de forma autónoma
            let result = executeCrossfade(config: config)
            if result == .started {
                // Actualizar NowPlaying con metadata de la siguiente canción
                if !nextSongTitle.isEmpty {
                    updateNowPlayingMetadata(
                        title: nextSongTitle,
                        artist: nextSongArtist,
                        album: nextSongAlbum,
                        duration: nextSongDuration,
                        artworkUrl: nil
                    )
                }
                // Notificar a JS (si está vivo, actualizará state; si está congelado, lo verá al despertar)
                plugin?.notifyListeners("onCrossfadeStart", data: [:])
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
        currentSongDuration = nextSongDuration > 0 ? nextSongDuration : Double(nextFile.length) / nextFile.processingFormat.sampleRate
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
                self.plugin?.notifyListeners("onTrackEnd", data: [:])
            }
        }

        playerA.play()
        isPlaying = true

        // Limpiar automix trigger del track anterior
        clearAutomixTrigger()

        startProgressTimer()
        updateNowPlayingMetadata(title: nextSongTitle, artist: nextSongArtist, album: nextSongAlbum, duration: currentSongDuration, artworkUrl: nil)
        updateNowPlayingPlaybackState()

        // Notificar a JS que cambió de canción (lo procesará al despertar)
        plugin?.notifyListeners("onNativeNext", data: [
            "title": currentSongTitle,
            "artist": currentSongArtist,
            "album": currentSongAlbum,
            "duration": currentSongDuration,
        ])

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
        var data: [String: Any] = [
            "isPlaying": isPlaying,
            "currentTime": currentTime(),
        ]
        if let reason = reason { data["reason"] = reason }
        plugin?.notifyListeners("onPlaybackStateChanged", data: data)
    }

    // MARK: - NowPlaying (directo, sin JS)

    func updateNowPlayingMetadata(title: String, artist: String, album: String, duration: Double, artworkUrl: String?) {
        let update = { [weak self] in
            guard let self = self else { return }
            self.currentSongTitle = title
            self.currentSongArtist = artist
            self.currentSongAlbum = album
            self.currentSongDuration = duration

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
            MPNowPlayingInfoCenter.default().playbackState = self.isPlaying ? .playing : .paused
            self.updateNowPlayingProgress()
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    private func clearNowPlaying() {
        localNowPlayingInfo = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Publica el diccionario local como una escritura atómica al singleton.
    /// Usar siempre en lugar de escribir directamente a MPNowPlayingInfoCenter.
    private func publishNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = localNowPlayingInfo
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
            // Enviar a JS
            self.plugin?.notifyListeners("onRemoteCommand", data: ["action": "next"])
            // Programar fallback nativo si JS no responde en 2s
            if self.hasNextFilePrepared {
                self.scheduleNativeNextFallback()
            }
            return .success
        }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.ensureAudioSessionActive()
            // Limpiar automix y cancelar crossfade (igual que next).
            self.clearAutomixTrigger()
            self.cancelCrossfade()
            // Delegar lógica a JS: si > 3s → seek(0), si <= 3s → canción anterior.
            // No hacer seek(0) nativo para evitar artefacto audible cuando JS decide
            // ir a la canción anterior (se oiría un reinicio breve antes del cambio).
            self.plugin?.notifyListeners("onRemoteCommand", data: ["action": "previous"])
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

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                pause()
                notifyPlaybackStateChanged(reason: "interruption")
            }
            print("[AudioEngineManager] Interrupción comenzada")

        case .ended:
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) && wasPlayingBeforeInterruption {
                ensureAudioSessionActive()
                // Pequeño delay para que iOS termine de restaurar la sesión
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.resume()
                }
                print("[AudioEngineManager] Interrupción terminada — reanudando")
            } else {
                print("[AudioEngineManager] Interrupción terminada — sin reanudar (shouldResume: \(options.contains(.shouldResume)))")
            }

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // Bluetooth/auriculares desconectados → pausar
            if isPlaying {
                pause()
                // Prevenir que handleInterruption(.ended) reanude tras route change:
                // en algunos dispositivos iOS envía interruption + routeChange juntos.
                wasPlayingBeforeInterruption = false
                notifyPlaybackStateChanged(reason: "routeLost")
            }
            // Safety net: asegurar que el lock screen muestre estado pausado.
            // En algunos edge cases (BT disconnect + reconfigure de audio route),
            // iOS puede resetear el playbackState brevemente. Re-setear tras un tick.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isPlaying else { return }
                MPNowPlayingInfoCenter.default().playbackState = .paused
                self.updateNowPlayingProgress()
            }
            print("[AudioEngineManager] Ruta perdida — pausado")

        case .newDeviceAvailable:
            reconfigureIOBuffer()
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
    var eqARef: AVAudioUnitEQ { eqA }
    var eqBRef: AVAudioUnitEQ { eqB }
    var mixerARef: AVAudioMixerNode { mixerA }
    var mixerBRef: AVAudioMixerNode { mixerB }
}
