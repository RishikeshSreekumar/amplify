import AudioToolbox
import Foundation
import os

/// Everything the audio thread needs to know. Plain values only, so it can be
/// copied on the real-time thread without allocating.
struct DSPParams: Equatable {
    /// Master boost, 1 = 100%.
    var boost: Float = 1
    /// Compressor that raises quiet parts ("Loudness").
    var loudness = false
    /// High-pass + presence lift for speech.
    var clarity = false
    /// Slow automatic gain that evens out loud and quiet sources.
    var autoLevel = false
    /// Virtual bass amount, 0 = off, 1 = max.
    var bass: Float = 0
    /// Stereo width: 0 = mono, 1 = unchanged, 2 = extra wide.
    var width: Float = 1
    /// -1 = left only, 0 = centre, 1 = right only.
    var balance: Float = 0
    /// Graphic EQ band gains in dB (first `EQ.bandCount` lanes are used).
    var eq = SIMD16<Float>()
    /// Gain per tap, in tap order. Tap 0 carries every app without its own level.
    var tapGains = SIMD16<Float>(repeating: 1)
}

enum EQ {
    static let bandCount = 10
    static let frequencies = SIMD16<Float>(32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000, 0, 0, 0, 0, 0, 0)
    static let maxGain: Float = 12
    static let q: Float = 1.41
}

enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bass = "Bass Boost"
    case treble = "Treble Boost"
    case vocal = "Vocal"
    case smile = "Loudness Curve"
    case custom = "Custom"

    var id: String { rawValue }

    /// Band gains in dB for 32 Hz … 16 kHz, or nil for the user's own curve.
    var gains: [Double]? {
        switch self {
        case .flat: return Array(repeating: 0, count: EQ.bandCount)
        case .bass: return [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .treble: return [0, 0, 0, 0, 0, 0, 1, 3, 5, 6]
        case .vocal: return [-3, -2, -1, 0, 2, 4, 4, 3, 1, 0]
        case .smile: return [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]
        case .custom: return nil
        }
    }
}

/// Second-order IIR filter (RBJ cookbook), transposed direct form II, with stereo state.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var l1: Float = 0, l2: Float = 0, r1: Float = 0, r2: Float = 0

    var isIdentity: Bool { b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 }

    @inline(__always) mutating func left(_ x: Float) -> Float {
        let y = b0 * x + l1
        l1 = b1 * x - a1 * y + l2
        l2 = b2 * x - a2 * y
        return y
    }

    @inline(__always) mutating func right(_ x: Float) -> Float {
        let y = b0 * x + r1
        r1 = b1 * x - a1 * y + r2
        r2 = b2 * x - a2 * y
        return y
    }

    mutating func clearState() { l1 = 0; l2 = 0; r1 = 0; r2 = 0 }

    /// Zeroes tiny state values so the filter never drifts into slow denormal math.
    mutating func flushDenormals() {
        if abs(l1) < 1e-15 { l1 = 0 }
        if abs(l2) < 1e-15 { l2 = 0 }
        if abs(r1) < 1e-15 { r1 = 0 }
        if abs(r2) < 1e-15 { r2 = 0 }
    }

    private mutating func set(_ b0: Float, _ b1: Float, _ b2: Float, _ a0: Float, _ a1: Float, _ a2: Float) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    mutating func identity() { b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0 }

    mutating func peaking(_ f: Float, q: Float, gain dB: Float, rate: Float) {
        guard dB != 0, f < rate * 0.45 else { return identity() }
        let a = powf(10, dB / 40), w = 2 * Float.pi * f / rate, alpha = sinf(w) / (2 * q), c = cosf(w)
        set(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }

    mutating func lowPass(_ f: Float, q: Float = 0.7071, rate: Float) {
        let w = 2 * Float.pi * min(f, rate * 0.45) / rate, alpha = sinf(w) / (2 * q), c = cosf(w)
        set((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    mutating func highPass(_ f: Float, q: Float = 0.7071, rate: Float) {
        let w = 2 * Float.pi * min(f, rate * 0.45) / rate, alpha = sinf(w) / (2 * q), c = cosf(w)
        set((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }
}

/// The real-time audio processor. Mixes the taps (each with its own gain), runs the
/// effects chain, applies the boost and a peak limiter, and writes to the output.
///
/// Chain: mix → EQ → voice clarity → virtual bass → stereo width/balance →
///        auto-level → loudness compressor → boost → limiter
///
/// `process` runs on the audio thread: no allocation, no blocking locks.
final class AudioProcessor: @unchecked Sendable {
    static let maxTaps = 16
    private static let maxChannels = 64
    private static let chunk = 512

    // Parameter handoff: the main thread writes `pending` under the lock; the audio
    // thread only *tries* the lock, so it never waits.
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let l = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
        return l
    }()
    private var pending = DSPParams()
    private var pendingVersion = 0
    private var params = DSPParams()
    private var version = -1

    // Meters, written by the audio thread and read (and reset) by the UI.
    private var meterIn: Float = 0
    private var meterOut: Float = 0
    private var meterReduction: Float = 1

    // Buffers and state, allocated once.
    private struct Channel { var data: UnsafeMutablePointer<Float>; var stride: Int }
    private let inputs = UnsafeMutablePointer<Channel>.allocate(capacity: maxChannels)
    private let outputs = UnsafeMutablePointer<Channel>.allocate(capacity: maxChannels)
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
    private let tapChannels = UnsafeMutablePointer<Int>.allocate(capacity: maxTaps)
    private var tapCount = 1
    private let tapGain = UnsafeMutablePointer<Float>.allocate(capacity: maxTaps)
    private let eq = UnsafeMutablePointer<Biquad>.allocate(capacity: EQ.bandCount)
    private let clarityFilters = UnsafeMutablePointer<Biquad>.allocate(capacity: 3)
    private let bassFilters = UnsafeMutablePointer<Biquad>.allocate(capacity: 4)

    private var rate: Float = 48_000
    private var smoothing: Float = 0
    private var gain: Float = 1
    private var reduction: Float = 1
    private var release: Float = 0
    /// Limiter ceiling, -1 dBFS.
    static let ceiling: Float = 0.891

    // Auto-level
    private var agcPower: Float = 0
    private var agcGain: Float = 1
    private var agcDetect: Float = 0, agcAttack: Float = 0, agcRelease: Float = 0
    static let agcTarget: Float = 0.1          // -20 dBFS RMS
    static let agcRange: ClosedRange<Float> = 0.5...4  // -6 … +12 dB

    // Loudness compressor
    private var compEnv: Float = 0
    private var compAttack: Float = 0, compRelease: Float = 0
    static let compThreshold: Float = -24, compRatio: Float = 3, compKnee: Float = 6
    static var compMakeup: Float { -compThreshold * (1 - 1 / compRatio) / 2 }

    init() {
        for i in 0..<Self.maxTaps { tapChannels[i] = 2; tapGain[i] = 1 }
        eq.initialize(repeating: Biquad(), count: EQ.bandCount)
        clarityFilters.initialize(repeating: Biquad(), count: 3)
        bassFilters.initialize(repeating: Biquad(), count: 4)
        reset(sampleRate: 48_000, tapChannels: [2])
    }

    deinit {
        [inputs, outputs].forEach { $0.deallocate() }
        [left, right, tapGain].forEach { $0.deallocate() }
        tapChannels.deallocate()
        eq.deallocate(); clarityFilters.deallocate(); bassFilters.deallocate()
        lock.deallocate()
    }

    /// Main thread: hand new parameters to the audio thread.
    func update(_ new: DSPParams) {
        os_unfair_lock_lock(lock)
        pending = new
        pendingVersion += 1
        os_unfair_lock_unlock(lock)
    }

    /// Main thread: peak in/out since the last call, and the deepest limiter reduction.
    func readMeters() -> (input: Float, output: Float, reduction: Float) {
        let m = (meterIn, meterOut, meterReduction)
        meterIn = 0; meterOut = 0; meterReduction = 1
        return m
    }

    /// Call before the audio callback starts. `tapChannels` lists each tap's channel
    /// count in the order their streams appear in the input buffer list.
    func reset(sampleRate: Double, tapChannels counts: [Int]) {
        rate = Float(sampleRate > 0 ? sampleRate : 48_000)
        tapCount = max(1, min(counts.count, Self.maxTaps))
        for i in 0..<tapCount { tapChannels[i] = max(1, counts.isEmpty ? 2 : counts[i]) }

        smoothing = coefficient(0.03)   // ~30 ms gain glide, no zipper noise
        release = coefficient(0.25)     // limiter release
        agcDetect = coefficient(0.4); agcAttack = coefficient(0.5); agcRelease = coefficient(3)
        compAttack = coefficient(0.005); compRelease = coefficient(0.12)

        clarityFilters[0].highPass(90, rate: rate)
        clarityFilters[1].peaking(300, q: 1, gain: -2, rate: rate)
        clarityFilters[2].peaking(3000, q: 0.9, gain: 5, rate: rate)
        bassFilters[0].lowPass(120, rate: rate)
        bassFilters[1].lowPass(120, rate: rate)
        bassFilters[2].highPass(90, rate: rate)   // harmonics band: drop DC and the fundamental
        bassFilters[3].lowPass(500, rate: rate)

        // Take the latest parameters now, without the audio thread running.
        os_unfair_lock_lock(lock)
        params = pending
        version = pendingVersion
        os_unfair_lock_unlock(lock)
        applyParams(previous: nil)
        gain = params.boost
        for i in 0..<Self.maxTaps { tapGain[i] = params.tapGains[i] }
        reduction = 1
        agcPower = 0; agcGain = 1; compEnv = 0
        for i in 0..<EQ.bandCount { eq[i].clearState() }
        for i in 0..<3 { clarityFilters[i].clearState() }
        for i in 0..<4 { bassFilters[i].clearState() }
    }

    private func coefficient(_ seconds: Float) -> Float { 1 - expf(-1 / (seconds * rate)) }

    private func pullParams() {
        guard os_unfair_lock_trylock(lock) else { return }
        if version != pendingVersion {
            let previous = params
            params = pending
            version = pendingVersion
            os_unfair_lock_unlock(lock)
            applyParams(previous: previous)
        } else {
            os_unfair_lock_unlock(lock)
        }
    }

    /// Recomputes filters for changed settings. Real-time safe (math only).
    private func applyParams(previous: DSPParams?) {
        if previous?.eq != params.eq {
            for i in 0..<EQ.bandCount {
                eq[i].peaking(EQ.frequencies[i], q: EQ.q, gain: min(max(params.eq[i], -EQ.maxGain), EQ.maxGain), rate: rate)
            }
        }
        if let previous {
            if params.autoLevel && !previous.autoLevel { agcPower = 0; agcGain = 1 }
            if params.loudness && !previous.loudness { compEnv = 0 }
            if params.clarity && !previous.clarity { for i in 0..<3 { clarityFilters[i].clearState() } }
            if params.bass > 0 && previous.bass == 0 { for i in 0..<4 { bassFilters[i].clearState() } }
        }
    }

    // MARK: - Audio thread

    func process(_ inList: UnsafePointer<AudioBufferList>, _ outList: UnsafeMutablePointer<AudioBufferList>) {
        pullParams()
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inList))
        let outs = UnsafeMutableAudioBufferListPointer(outList)
        var frames = Int.max

        // The taps' streams come last, after any input streams of the output device.
        var wanted = 0
        for t in 0..<tapCount { wanted += tapChannels[t] }
        var first = ins.count
        var found = 0
        while first > 0 && found < wanted {
            first -= 1
            found += Int(ins[first].mNumberChannels)
        }
        var inCount = 0
        for b in first..<ins.count { collect(ins[b], into: inputs, &inCount, &frames) }
        var outCount = 0
        for b in outs { collect(b, into: outputs, &outCount, &frames) }
        guard outCount > 0, frames != .max else { return }

        var offset = 0
        while offset < frames {
            let n = min(Self.chunk, frames - offset)
            mix(n, offset, inCount)
            effects(n)
            write(n, offset, outCount)
            offset += n
        }

        for i in 0..<EQ.bandCount { eq[i].flushDenormals() }
        for i in 0..<3 { clarityFilters[i].flushDenormals() }
        for i in 0..<4 { bassFilters[i].flushDenormals() }
    }

    private func collect(_ buffer: AudioBuffer, into list: UnsafeMutablePointer<Channel>, _ count: inout Int, _ frames: inout Int) {
        let channels = Int(buffer.mNumberChannels)
        guard let data = buffer.mData, channels > 0 else { return }
        frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        let samples = data.assumingMemoryBound(to: Float.self)
        for c in 0..<channels where count < Self.maxChannels {
            list[count] = Channel(data: samples + c, stride: channels)
            count += 1
        }
    }

    /// Sums the taps into the left/right work buffers, each with its own (smoothed) gain.
    private func mix(_ n: Int, _ offset: Int, _ inCount: Int) {
        left.update(repeating: 0, count: n)
        right.update(repeating: 0, count: n)
        var c = 0
        for t in 0..<tapCount {
            let channels = tapChannels[t]
            guard c + channels <= inCount else { break }
            let l = inputs[c], r = inputs[channels > 1 ? c + 1 : c]
            let target = params.tapGains[t]
            var g = tapGain[t]
            for i in 0..<n {
                g += (target - g) * smoothing
                let f = offset + i
                left[i] += l.data[f * l.stride] * g
                right[i] += r.data[f * r.stride] * g
            }
            tapGain[t] = g
            c += channels
        }
    }

    private func effects(_ n: Int) {
        let p = params
        let eqOn = (0..<EQ.bandCount).contains { p.eq[$0] != 0 }
        var peakIn: Float = 0, peakOut: Float = 0, deepest: Float = 1

        for i in 0..<n {
            var l = left[i], r = right[i]
            peakIn = max(peakIn, abs(l), abs(r))

            if eqOn {
                for b in 0..<EQ.bandCount where !eq[b].isIdentity {
                    l = eq[b].left(l)
                    r = eq[b].right(r)
                }
            }

            if p.clarity {
                for b in 0..<3 {
                    l = clarityFilters[b].left(l)
                    r = clarityFilters[b].right(r)
                }
            }

            if p.bass > 0 {
                // Psychoacoustic bass: rectify the lows to create harmonics small
                // speakers can play; the ear fills in the missing fundamental.
                var low = bassFilters[0].left((l + r) * 0.5)
                low = bassFilters[1].left(low)
                var h = bassFilters[2].left(abs(low))
                h = bassFilters[3].left(h)
                let add = h * p.bass * 2
                l += add
                r += add
            }

            if p.width != 1 {
                let m = (l + r) * 0.5, s = (l - r) * 0.5 * p.width
                l = m + s
                r = m - s
            }
            if p.balance != 0 {
                l *= min(1, 1 - p.balance)
                r *= min(1, 1 + p.balance)
            }

            if p.autoLevel {
                agcPower += ((l * l + r * r) * 0.5 - agcPower) * agcDetect
                let rms = agcPower.squareRoot()
                if rms > 0.001 {  // don't pump up silence (-60 dBFS gate)
                    let target = min(max(Self.agcTarget / rms, Self.agcRange.lowerBound), Self.agcRange.upperBound)
                    agcGain += (target - agcGain) * (target < agcGain ? agcAttack : agcRelease)
                }
                l *= agcGain
                r *= agcGain
            }

            if p.loudness {
                let level = max(abs(l), abs(r))
                compEnv += (level - compEnv) * (level > compEnv ? compAttack : compRelease)
                let g = Self.compressorGain(envelope: compEnv)
                l *= g
                r *= g
            }

            // Boost, then the limiter: instant attack, smooth release, -1 dBFS ceiling.
            gain += (p.boost - gain) * smoothing
            l *= gain
            r *= gain
            let peak = max(abs(l), abs(r))
            reduction += (1 - reduction) * release
            if peak * reduction > Self.ceiling { reduction = Self.ceiling / peak }
            l *= reduction
            r *= reduction
            deepest = min(deepest, reduction)
            peakOut = max(peakOut, abs(l), abs(r))

            left[i] = l
            right[i] = r
        }

        meterIn = max(meterIn, peakIn)
        meterOut = max(meterOut, peakOut)
        meterReduction = min(meterReduction, deepest)
    }

    /// Static compressor curve (soft knee) plus makeup gain, as a linear multiplier.
    static func compressorGain(envelope: Float) -> Float {
        let db = 20 * log10f(max(envelope, 1e-6))
        let over = db - compThreshold
        let slope = 1 - 1 / compRatio
        let reductionDB: Float
        if over <= -compKnee / 2 {
            reductionDB = 0
        } else if over < compKnee / 2 {
            let x = over + compKnee / 2
            reductionDB = slope * x * x / (2 * compKnee)
        } else {
            reductionDB = slope * over
        }
        return powf(10, (compMakeup - reductionDB) / 20)
    }

    private func write(_ n: Int, _ offset: Int, _ outCount: Int) {
        for c in 0..<outCount {
            let o = outputs[c]
            for i in 0..<n {
                let sample: Float
                if outCount == 1 {
                    sample = (left[i] + right[i]) * 0.5
                } else if c == 0 {
                    sample = left[i]
                } else if c == 1 {
                    sample = right[i]
                } else {
                    sample = 0
                }
                o.data[(offset + i) * o.stride] = sample
            }
        }
    }
}
