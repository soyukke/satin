import AVFoundation
import AppKit
import os

/// One note of the synthesizer: an oscillator through a one-pole low-pass,
/// shaped by a linear attack and an exponential release.
struct NativeChillVoice {
    var frequency: Double
    var start: Double
    var duration: Double
    var triangle = false
    var peak: Float = 0.08
    var attack: Double = 0.02
    var cutoff: Double = 2400
}

/// The soft, slow sounds Satin plays when sound is on: a pad loop under the
/// work, and a short chime when an agent waits, fails or finishes.
final class NativeChillSound {
    // Fmaj9, Em7, Dm9, Cmaj7: a slow loop that never resolves.
    static let chords: [[Int]] = [
        [53, 57, 60, 64, 67], [52, 55, 59, 62], [50, 53, 57, 60, 64], [48, 52, 55, 59],
    ]
    static let chordSeconds = 7.0

    var ambient = false {
        didSet {
            guard ambient != oldValue else { return }
            updateAmbient()
        }
    }
    var chimes = false

    private let synth = NativeChillSynth()
    private var engine: AVAudioEngine?
    private var chordTimer: Timer?
    private var chordIndex = 0
    private var idleStop: DispatchWorkItem?

    /// Plays the chime for a status an agent has just moved to.
    func chime(for status: String) {
        guard chimes, let notes = Self.chime(for: status) else {
            return
        }
        play(notes)
    }

    /// The color an event floods the backdrop with.
    static func tint(for status: String) -> NSColor? {
        switch status {
        case "waiting": NSColor(srgbRed: 0.95, green: 0.64, blue: 0.23, alpha: 1)
        case "failed", "blocked": NSColor(srgbRed: 0.94, green: 0.35, blue: 0.44, alpha: 1)
        case "done": NSColor(srgbRed: 0.44, green: 0.83, blue: 0.61, alpha: 1)
        default: nil
        }
    }

    static func chime(for status: String) -> [NativeChillVoice]? {
        switch status {
        case "waiting":
            return [
                NativeChillVoice(frequency: hertz(76), start: 0, duration: 1.6, peak: 0.07),
                NativeChillVoice(frequency: hertz(83), start: 0.18, duration: 1.8, peak: 0.06),
            ]
        case "failed", "blocked":
            return [
                NativeChillVoice(
                    frequency: hertz(45), start: 0, duration: 1.2, peak: 0.12, cutoff: 500),
                NativeChillVoice(
                    frequency: hertz(51), start: 0.12, duration: 1.0, triangle: true, peak: 0.04,
                    cutoff: 700),
            ]
        case "done":
            return [72, 76, 79, 83].enumerated().map { index, note in
                NativeChillVoice(
                    frequency: hertz(note), start: Double(index) * 0.09, duration: 1.4,
                    triangle: true, peak: 0.05, cutoff: 2600)
            }
        default:
            return nil
        }
    }

    static func pad(_ notes: [Int]) -> [NativeChillVoice] {
        var voices = notes.enumerated().map { index, note in
            NativeChillVoice(
                frequency: hertz(note) * pow(2, Double(index % 2 == 0 ? -6 : 6) / 1200),
                start: Double(index) * 0.06, duration: chordSeconds + 0.5, triangle: true,
                peak: 0.025, attack: 2.2, cutoff: 900)
        }
        voices.append(
            NativeChillVoice(
                frequency: hertz(notes[0] - 12), start: 0, duration: chordSeconds + 0.5,
                peak: 0.05, attack: 1.5, cutoff: 400))
        return voices
    }

    static func hertz(_ note: Int) -> Double {
        440 * pow(2, Double(note - 69) / 12)
    }

    private func updateAmbient() {
        chordTimer?.invalidate()
        chordTimer = nil
        synth.setVinyl(ambient)
        guard ambient else {
            scheduleIdleStop(after: Self.chordSeconds + 2)
            return
        }
        playChord()
        let timer = Timer(timeInterval: Self.chordSeconds, repeats: true) { [weak self] _ in
            self?.playChord()
        }
        RunLoop.main.add(timer, forMode: .common)
        chordTimer = timer
    }

    private func playChord() {
        let notes = Self.chords[chordIndex % Self.chords.count]
        chordIndex += 1
        play(Self.pad(notes))
    }

    private func play(_ voices: [NativeChillVoice]) {
        guard startEngine() else { return }
        synth.add(voices)
        if !ambient {
            let tail = voices.map { $0.start + $0.duration }.max() ?? 0
            scheduleIdleStop(after: tail + 2)
        }
    }

    /// The engine runs only while something sounds, so a silent Satin keeps
    /// the audio hardware asleep.
    private func startEngine() -> Bool {
        idleStop?.cancel()
        idleStop = nil
        if let engine, engine.isRunning {
            return true
        }
        let engine = engine ?? makeEngine()
        self.engine = engine
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        let output = engine.outputNode.outputFormat(forBus: 0)
        let rate = output.sampleRate > 0 ? output.sampleRate : 48_000
        synth.prepare(sampleRate: rate)
        let synth = self.synth
        let source = AVAudioSourceNode { _, _, frameCount, buffers in
            synth.render(
                frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(buffers))
            return noErr
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        return engine
    }

    private func scheduleIdleStop(after seconds: Double) {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ambient else { return }
            self.engine?.stop()
            self.synth.reset()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// The render side of NativeChillSound. The audio thread owns everything but
/// the pending queue, which the main thread fills under a lock the audio
/// thread only tries.
final class NativeChillSynth: @unchecked Sendable {
    private struct Playing {
        var voice: NativeChillVoice
        var phase = 0.0
        var step = 0.0
        var age = 0
        var delay = 0
        var attack = 1
        var length = 1
        var release: Float = 1
        var level: Float = 0
        var filtered: Float = 0
        var coefficient: Float = 0
    }

    private var lock = os_unfair_lock()
    private var pending: [NativeChillVoice] = []
    private var vinylPending: Bool?
    private var clearPending = false

    private var rate = 48_000.0
    private var playing: [Playing] = []
    private var echo: [Float] = []
    private var echoIndex = 0
    private var echoTone: Float = 0
    private var vinyl = false
    private var vinylLevel: Float = 0
    private var hissLow: Float = 0
    private var hissHigh: Float = 0
    private var noise: UInt32 = 0x9E37_79B9

    static let master: Float = 0.5
    static let echoSeconds = 0.38
    static let echoFeedback: Float = 0.32
    static let echoWet: Float = 0.35
    static let vinylGain: Float = 0.004

    func prepare(sampleRate: Double) {
        rate = sampleRate
        echo = [Float](repeating: 0, count: max(1, Int(sampleRate * Self.echoSeconds)))
        echoIndex = 0
        playing.reserveCapacity(64)
    }

    func add(_ voices: [NativeChillVoice]) {
        os_unfair_lock_lock(&lock)
        pending.append(contentsOf: voices)
        os_unfair_lock_unlock(&lock)
    }

    func setVinyl(_ on: Bool) {
        os_unfair_lock_lock(&lock)
        vinylPending = on
        os_unfair_lock_unlock(&lock)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        clearPending = true
        os_unfair_lock_unlock(&lock)
    }

    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        takePending()
        let echoCoefficient = Self.onePole(cutoff: 2400, rate: rate)
        let hissLowCoefficient = Self.onePole(cutoff: 5200, rate: rate)
        let hissHighCoefficient = Self.onePole(cutoff: 1800, rate: rate)
        let vinylTarget: Float = vinyl ? Self.vinylGain : 0
        for frame in 0..<frames {
            var bus: Float = 0
            for index in playing.indices {
                bus += next(&playing[index])
            }
            let echoed = echo.isEmpty ? 0 : echo[echoIndex]
            echoTone += echoCoefficient * (echoed - echoTone)
            if !echo.isEmpty {
                echo[echoIndex] = bus + Self.echoFeedback * echoTone
                echoIndex = (echoIndex + 1) % echo.count
            }
            vinylLevel += 0.00002 * (vinylTarget - vinylLevel)
            var hiss: Float = 0
            if vinylLevel > 0.0001 {
                var grain = randomUnit() * 0.35
                if randomUnit() > 0.9988 {
                    grain += randomUnit() * 3
                }
                hissLow += hissLowCoefficient * (grain - hissLow)
                hissHigh += hissHighCoefficient * (hissLow - hissHigh)
                hiss = (hissLow - hissHigh) * vinylLevel
            }
            let sample = Self.master * (bus + Self.echoWet * echoTone) + hiss
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
        playing.removeAll { $0.age >= $0.delay + $0.length }
    }

    private func takePending() {
        guard os_unfair_lock_trylock(&lock) else { return }
        let voices = pending
        pending.removeAll(keepingCapacity: true)
        let vinylChange = vinylPending
        vinylPending = nil
        let clear = clearPending
        clearPending = false
        os_unfair_lock_unlock(&lock)
        if clear {
            playing.removeAll(keepingCapacity: true)
            for index in echo.indices {
                echo[index] = 0
            }
            echoTone = 0
        }
        if let vinylChange {
            vinyl = vinylChange
        }
        for voice in voices {
            let attack = max(1, Int(voice.attack * rate))
            let length = max(attack + 1, Int(voice.duration * rate))
            playing.append(
                Playing(
                    voice: voice,
                    step: voice.frequency / rate,
                    delay: Int(voice.start * rate),
                    attack: attack,
                    length: length,
                    release: Float(pow(0.0001, 1 / Double(length - attack))),
                    coefficient: Self.onePole(cutoff: voice.cutoff, rate: rate)
                ))
        }
    }

    private func next(_ note: inout Playing) -> Float {
        note.age += 1
        let age = note.age - note.delay
        guard age > 0 else { return 0 }
        if age <= note.attack {
            note.level = note.voice.peak * Float(age) / Float(note.attack)
        } else {
            note.level *= note.release
        }
        note.phase += note.step
        if note.phase >= 1 {
            note.phase -= 1
        }
        let wave: Float =
            note.voice.triangle
            ? Float(4 * abs(note.phase - 0.5) - 1)
            : Float(sin(2 * Double.pi * note.phase))
        note.filtered += note.coefficient * (wave - note.filtered)
        return note.filtered * note.level
    }

    private func randomUnit() -> Float {
        noise ^= noise << 13
        noise ^= noise >> 17
        noise ^= noise << 5
        return Float(noise) / Float(UInt32.max) * 2 - 1
    }

    static func onePole(cutoff: Double, rate: Double) -> Float {
        Float(1 - exp(-2 * Double.pi * cutoff / rate))
    }
}

func nativeChillSoundSelfTestPassed() -> Bool {
    guard NativeChillSound.chime(for: "running") == nil,
        NativeChillSound.tint(for: "running") == nil,
        NativeChillSound.tint(for: "done") != nil,
        NativeChillSound.chime(for: "waiting")?.count == 2,
        NativeChillSound.chime(for: "blocked")?.count == 2,
        NativeChillSound.chime(for: "done")?.count == 4,
        NativeChillSound.pad(NativeChillSound.chords[0]).count == 6,
        abs(NativeChillSound.hertz(69) - 440) < 0.001
    else {
        return false
    }
    let synth = NativeChillSynth()
    synth.prepare(sampleRate: 48_000)
    synth.add(NativeChillSound.chime(for: "done") ?? [])
    var left = [Float](repeating: 0, count: 4800)
    var loudest: Float = 0
    left.withUnsafeMutableBufferPointer { samples in
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { list.unsafeMutablePointer.deallocate() }
        list[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(samples.count * 4),
            mData: UnsafeMutableRawPointer(samples.baseAddress))
        synth.render(frames: samples.count, into: list)
        loudest = samples.reduce(0) { max($0, abs($1)) }
    }
    // A chime is heard, and stays well below clipping.
    return loudest > 0.001 && loudest < 0.5
}
