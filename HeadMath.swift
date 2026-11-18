import Foundation
import CoreMotion

/// Converte a orientacao do iPhone (CoreMotion) para o quaternion de cabeca que o driver StormVR espera
/// (referencial do SteamVR: x direita, y cima, -z frente). Mesma matematica do HeadTracker.kt do app Android.
enum HeadMath {
    struct Quat { var w: Double; var x: Double; var y: Double; var z: Double }

    /// topRight = true: o TOPO do iPhone fica do lado DIREITO do seu rosto (iPhone deitado, dentro do oculos).
    static func quaternion(from m: CMRotationMatrix, topRight: Bool) -> Quat {
        // CoreMotion: matriz referencia->aparelho. Android: aparelho->mundo. Entao usamos a transposta.
        let r: [Double] = [m.m11, m.m21, m.m31,
                           m.m12, m.m22, m.m32,
                           m.m13, m.m23, m.m33]
        // mundo (x leste, y norte, z cima) -> SteamVR (x = x, y = z, z = -y)
        let a: [Double] = [ r[0],  r[1],  r[2],
                            r[6],  r[7],  r[8],
                           -r[3], -r[4], -r[5]]
        // eixos da CABECA expressos no aparelho deitado
        var b = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            let c0 = a[i * 3], c1 = a[i * 3 + 1], c2 = a[i * 3 + 2]
            if topRight { b[i * 3] = c1;  b[i * 3 + 1] = -c0 }
            else        { b[i * 3] = -c1; b[i * 3 + 1] = c0 }
            b[i * 3 + 2] = c2
        }
        return matrixToQuat(b)
    }

    private static func matrixToQuat(_ m: [Double]) -> Quat {
        let t = m[0] + m[4] + m[8]
        var qw: Double, qx: Double, qy: Double, qz: Double
        if t > 0 {
            let s = (t + 1).squareRoot() * 2
            qw = 0.25 * s; qx = (m[7] - m[5]) / s; qy = (m[2] - m[6]) / s; qz = (m[3] - m[1]) / s
        } else if m[0] > m[4] && m[0] > m[8] {
            let s = (1 + m[0] - m[4] - m[8]).squareRoot() * 2
            qw = (m[7] - m[5]) / s; qx = 0.25 * s; qy = (m[1] + m[3]) / s; qz = (m[2] + m[6]) / s
        } else if m[4] > m[8] {
            let s = (1 + m[4] - m[0] - m[8]).squareRoot() * 2
            qw = (m[2] - m[6]) / s; qx = (m[1] + m[3]) / s; qy = 0.25 * s; qz = (m[5] + m[7]) / s
        } else {
            let s = (1 + m[8] - m[0] - m[4]).squareRoot() * 2
            qw = (m[3] - m[1]) / s; qx = (m[2] + m[6]) / s; qy = (m[5] + m[7]) / s; qz = 0.25 * s
        }
        let n = (qw * qw + qx * qx + qy * qy + qz * qz).squareRoot()
        if n > 0 { qw /= n; qx /= n; qy /= n; qz /= n }
        return Quat(w: qw, x: qx, y: qy, z: qz)
    }

    /// So para mostrar na tela e conferir o sentido: yaw (+ = virar para a ESQUERDA), pitch (+ = olhar para CIMA).
    static func eulerDegrees(_ q: Quat) -> (yaw: Double, pitch: Double, roll: Double) {
        let yaw = atan2(2 * (q.x * q.z + q.w * q.y), 1 - 2 * (q.x * q.x + q.y * q.y))
        let pitch = asin(max(-1, min(1, 2 * (q.w * q.x - q.y * q.z))))
        let roll = atan2(-2 * (q.x * q.y - q.w * q.z), 1 - 2 * (q.x * q.x + q.z * q.z))
        let k = 180.0 / Double.pi
        return (yaw * k, pitch * k, roll * k)
    }
}
