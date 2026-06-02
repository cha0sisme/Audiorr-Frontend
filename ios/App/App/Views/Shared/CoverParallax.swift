import SwiftUI
import CoreMotion

/// Provee la inclinación del dispositivo (roll/pitch normalizados a −1…1,
/// relativos a la orientación al activarse) para el efecto parallax de las
/// covers ESTÁTICAS — el "animated artwork" sintético al estilo Apple Music
/// para álbumes sin vídeo motion real.
///
/// Singleton con conteo de referencias: un único `CMMotionManager` para toda
/// la app, que se enciende solo mientras haya alguna cover visible. En
/// simulador (sin giroscopio) los valores quedan en 0 → la cover se ve normal,
/// sin efecto.
final class MotionParallaxProvider: ObservableObject {
    static let shared = MotionParallaxProvider()

    @Published private(set) var roll: Double = 0   // −1…1 (inclinación izq/der)
    @Published private(set) var pitch: Double = 0  // −1…1 (inclinación arriba/abajo)

    private let manager = CMMotionManager()
    private var refCount = 0
    private var refRoll: Double?
    private var refPitch: Double?

    private init() {}

    func start() {
        refCount += 1
        guard refCount == 1 else { return }
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        // `to: .main` → el handler corre en el hilo principal; seguro para
        // mutar @Published.
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            // La primera lectura fija la referencia: el efecto es 0 en la
            // orientación en la que el usuario abrió la pantalla.
            if self.refRoll == nil {
                self.refRoll = m.attitude.roll
                self.refPitch = m.attitude.pitch
            }
            let maxRad = 0.6   // ~34° para alcanzar el máximo
            self.roll = max(-1, min(1, (m.attitude.roll - (self.refRoll ?? 0)) / maxRad))
            self.pitch = max(-1, min(1, (m.attitude.pitch - (self.refPitch ?? 0)) / maxRad))
        }
    }

    func stop() {
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        manager.stopDeviceMotionUpdates()
        refRoll = nil
        refPitch = nil
        roll = 0
        pitch = 0
    }
}

/// Inclina sutilmente una cover estática según el giroscopio (parallax 3D + un
/// leve desplazamiento), dándole un toque "vivo" tipo animated artwork sin
/// necesidad de vídeo. Pensado SOLO para covers estáticas (sin motion real);
/// donde hay vídeo motion no se aplica porque el propio vídeo ya da el efecto.
struct CoverParallax: ViewModifier {
    @ObservedObject private var motion = MotionParallaxProvider.shared
    var maxAngle: Double = 5     // grados de inclinación
    var maxShift: CGFloat = 5    // px de desplazamiento

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(motion.roll * maxAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(-motion.pitch * maxAngle), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .offset(x: CGFloat(motion.roll) * maxShift, y: CGFloat(motion.pitch) * maxShift)
            .animation(.interactiveSpring(response: 0.5, dampingFraction: 0.85), value: motion.roll)
            .animation(.interactiveSpring(response: 0.5, dampingFraction: 0.85), value: motion.pitch)
            .onAppear { motion.start() }
            .onDisappear { motion.stop() }
    }
}

extension View {
    /// Parallax sutil por giroscopio para covers estáticas (animated artwork
    /// sintético estilo Apple Music). En simulador no hace nada.
    func coverParallax(maxAngle: Double = 5, maxShift: CGFloat = 5) -> some View {
        modifier(CoverParallax(maxAngle: maxAngle, maxShift: maxShift))
    }
}
