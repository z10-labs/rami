// rami-rec: record a meeting on this Mac and transcribe it live, on device.
// Screen and system audio come from ScreenCaptureKit, the microphone from
// AVAudioEngine, and speech from SpeechTranscriber (macOS 26). Nothing leaves
// the machine. Built by the installer with swiftc; brain_meet.py drives it.
//
//   rami-rec check                      JSON: what is available and permitted
//   rami-rec calls                      JSON: who else uses the mic, which call apps run
//   rami-rec ask --app NAME             pop-up "Record this call?"; JSON {"record": bool}
//   rami-rec record --out DIR [--no-screen] [--no-system] [--no-mic] [--locale ID] [--max-minutes N]
//   rami-rec transcribe FILE --out DIR [--who you|them] [--locale ID]
//
// Files in DIR: transcript.jsonl (one final line per JSON object: t, end, who,
// text), live.json (state, elapsed, volatile text and levels; rewritten twice a
// second), audio-you.m4a, audio-them.m4a, screen.mov, and done.json at the end.
// SIGINT or SIGTERM stops a recording cleanly.
import AVFoundation
import AppKit
import CoreAudio
import Foundation
import ScreenCaptureKit
import Speech

let LIVE_INTERVAL = 0.5
let CALL_APPS: [String: String] = [
    "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
    "com.apple.FaceTime": "FaceTime", "com.cisco.webexmeetingsapp": "Webex", "com.hnc.Discord": "Discord",
    "com.tinyspeck.slackmacgap": "Slack",
]
// System services that take input on our behalf (our own transcription) or on their own (Siri).
let SYSTEM_LISTENERS: Set<String> = ["com.apple.CoreSpeech", "com.apple.corespeechd", "com.apple.SpeechRecognitionCore",
                                     "com.apple.siri", "com.apple.assistantd", "com.apple.DictationIM"]
let BROWSERS: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                             "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"]

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("rami-rec: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func printJSON(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

// ---------------------------------------------------------------- output

final class Out: @unchecked Sendable {
    let dir: URL
    let start = Date()
    private let q = DispatchQueue(label: "rami-rec.out")
    private let handle: FileHandle
    private var heard: [String: String] = [:]
    private var levels: [String: Double] = [:]
    private var _state = "preparing"
    private var _screen = false
    // Set from capture, signal and main threads; read on q when live.json is written.
    var state: String {
        get { q.sync { _state } }
        set { q.async { self._state = newValue } }
    }
    var screen: Bool {
        get { q.sync { _screen } }
        set { q.async { self._screen = newValue } }
    }
    var errors: [String] = []

    init(dir: URL) throws {
        self.dir = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("transcript.jsonl")
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: path)
        handle.seekToEndOfFile()
    }

    var elapsed: Double { Date().timeIntervalSince(start) }

    func line(_ obj: [String: Any]) {
        q.async {
            guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            self.handle.write(data)
        }
    }

    func setHeard(_ who: String, _ text: String) { q.async { self.heard[who] = text } }

    // Peak-hold with decay, so the page's meter does not flicker.
    func setLevel(_ who: String, _ v: Double) {
        q.async { self.levels[who] = max(min(v, 1), (self.levels[who] ?? 0) * 0.7) }
    }

    func note(_ err: String) {
        FileHandle.standardError.write(("rami-rec: " + err + "\n").data(using: .utf8)!)
        q.async { self.errors.append(err) }
    }

    func flushLive() {
        q.async {
            let obj: [String: Any] = ["state": self._state, "elapsed": round2(self.elapsed), "heard": self.heard,
                                      "levels": self.levels.mapValues { round2($0) }, "screen": self._screen,
                                      "errors": self.errors, "pid": Int(getpid())]
            self.writeAtomic("live.json", obj)
        }
    }

    func finish(_ extra: [String: Any]) {
        q.sync {
            handle.synchronizeFile()
            var obj = extra
            obj["duration"] = round2(elapsed)
            obj["errors"] = errors
            writeAtomic("done.json", obj)
        }
    }

    private func writeAtomic(_ name: String, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}

// ---------------------------------------------------------------- speech

func speechLocale(_ id: String?) async -> Locale? {
    let want = id.map { Locale(identifier: $0) } ?? Locale.current
    return await SpeechTranscriber.supportedLocale(equivalentTo: want)
}

// One audio source (you or them): converts buffers to the analyzer's format,
// keeps a compressed copy on disk, and turns results into transcript lines.
final class Source: @unchecked Sendable {
    let who: String
    let out: Out
    let format: AVAudioFormat
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let cont: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var offset: Double?
    private var results: Task<Void, Never>?
    private let lock = NSLock()

    init(who: String, out: Out, locale: Locale, keepAudio: Bool) async throws {
        self.who = who
        self.out = out
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        try await Source.ensureModel(transcriber, locale)
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "rami-rec", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio format for speech"])
        }
        format = fmt
        let (stream, c) = AsyncStream.makeStream(of: AnalyzerInput.self)
        cont = c
        analyzer = SpeechAnalyzer(modules: [transcriber])
        if keepAudio {
            let url = out.dir.appendingPathComponent("audio-\(who).m4a")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: fmt.sampleRate,
                                           AVNumberOfChannelsKey: Int(fmt.channelCount)]
            do {
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: fmt.commonFormat,
                                       interleaved: fmt.isInterleaved)
            } catch {
                out.note("cannot write \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        try await analyzer.prepareToAnalyze(in: fmt)
        try await analyzer.start(inputSequence: stream)
        let tr = transcriber
        results = Task { [weak self] in
            do {
                for try await r in tr.results { self?.take(r) }
            } catch {
                self?.out.note("\(who) transcription stopped: \(error.localizedDescription)")
            }
        }
    }

    // The language model is downloaded once by the system; skip the request
    // when it is already installed (the request itself can fail offline).
    static func ensureModel(_ tr: SpeechTranscriber, _ locale: Locale) async throws {
        let id = locale.identifier(.bcp47)
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == id }) { return }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) {
            try await req.downloadAndInstall()
        }
    }

    private func take(_ r: SpeechTranscriber.Result) {
        let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.isFinal else { out.setHeard(who, text); return }
        out.setHeard(who, "")
        guard !text.isEmpty else { return }
        let base = offset ?? 0
        let t0 = r.range.start.isNumeric ? r.range.start.seconds : 0
        let dur = r.range.duration.isNumeric ? r.range.duration.seconds : 0
        out.line(["t": round2(base + t0), "end": round2(base + t0 + dur), "who": who, "text": text])
    }

    func feed(_ buf: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if offset == nil { offset = out.elapsed }
        out.setLevel(who, level(buf))
        if converter == nil || converter!.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: format)
        }
        guard let conv = converter else { return }
        let ratio = format.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buf
        }
        if err != nil || outBuf.frameLength == 0 { return }
        cont.yield(AnalyzerInput(buffer: outBuf))
        if let f = file {
            do { try f.write(from: outBuf) } catch {
                file = nil
                out.note("stopped saving \(who) audio: \(error.localizedDescription)")
            }
        }
    }

    func finish() async {
        cont.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch {
            out.note("\(who) finalize: \(error.localizedDescription)")
        }
        await results?.value
        closeFile()
    }

    private func closeFile() {
        lock.lock()
        file = nil   // closes the file
        lock.unlock()
    }
}

func level(_ buf: AVAudioPCMBuffer) -> Double {
    guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return 0 }
    var sum: Float = 0
    let n = Int(buf.frameLength)
    for i in 0..<n { sum += ch[0][i] * ch[0][i] }
    let rms = sqrt(Double(sum) / Double(n))
    // Speech sits around -30 dBFS; map -60..0 dB to 0..1.
    let db = 20 * log10(max(rms, 1e-6))
    return max(0, min(1, (db + 60) / 60))
}

// ---------------------------------------------------------------- capture

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    let out: Out
    var you: Source?
    var them: Source?
    var engine: AVAudioEngine?
    var stream: SCStream?
    var recording: SCRecordingOutput?
    private var recordingDone: CheckedContinuation<Void, Never>?
    private let doneLock = NSLock()
    private let audioQ = DispatchQueue(label: "rami-rec.audio")

    init(out: Out) { self.out = out }

    func startMic() throws {
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw NSError(domain: "rami-rec", code: 2, userInfo: [NSLocalizedDescriptionKey: "no microphone"]) }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in self?.you?.feed(buf) }
        try eng.start()
        engine = eng
    }

    func startScreen(video: Bool, audio: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let main = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == main }) ?? content.displays.first else {
            throw NSError(domain: "rami-rec", code: 3, userInfo: [NSLocalizedDescriptionKey: "no display to capture"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = audio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        if video {
            cfg.width = display.width
            cfg.height = display.height
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            cfg.showsCursor = true
        } else {
            cfg.width = 16
            cfg.height = 16
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        if audio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ) }
        if video {
            let rc = SCRecordingOutputConfiguration()
            rc.outputURL = out.dir.appendingPathComponent("screen.mov")
            rc.outputFileType = .mov
            let ro = SCRecordingOutput(configuration: rc, delegate: self)
            try s.addRecordingOutput(ro)
            recording = ro
        }
        try await s.startCapture()
        stream = s
        out.screen = video
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let buf = pcm(sb) else { return }
        them?.feed(buf)
    }

    // "Stop sharing" in the menu bar, a display change or a capture error: the
    // mic keeps recording, and the page is told the screen is off.
    func stream(_ s: SCStream, didStopWithError error: Error) {
        out.screen = false
        out.note("screen and system audio stopped: \(error.localizedDescription)")
        resumeRecordingDone()
    }

    func recordingOutput(_ ro: SCRecordingOutput, didFailWithError error: Error) {
        out.note("screen recording failed: \(error.localizedDescription)")
        resumeRecordingDone()
    }

    func recordingOutputDidFinishRecording(_ ro: SCRecordingOutput) {
        resumeRecordingDone()
    }

    // Callbacks and the timeout race; a continuation may resume only once.
    private func setRecordingDone(_ c: CheckedContinuation<Void, Never>) {
        doneLock.lock()
        recordingDone = c
        doneLock.unlock()
    }

    private func resumeRecordingDone() {
        doneLock.lock()
        let c = recordingDone
        recordingDone = nil
        doneLock.unlock()
        c?.resume()
    }

    func stop() async {
        out.state = "stopping"
        out.flushLive()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        if let s = stream {
            if recording != nil {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    setRecordingDone(c)
                    Task {
                        do { try await s.stopCapture() } catch { self.out.note("stop capture: \(error.localizedDescription)") }
                        try? await Task.sleep(nanoseconds: 5_000_000_000)   // never wait forever
                        self.resumeRecordingDone()
                    }
                }
            } else {
                do { try await s.stopCapture() } catch { out.note("stop capture: \(error.localizedDescription)") }
            }
        }
        await you?.finish()
        await them?.finish()
    }
}

func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let desc = sb.formatDescription else { return nil }
    let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
    let n = AVAudioFrameCount(sb.numSamples)
    guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
    buf.frameLength = n
    let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
    return st == noErr ? buf : nil
}

// ---------------------------------------------------------------- commands

struct Args {
    var cmd = ""
    var file: String?
    var out: String?
    var locale: String?
    var who = "them"
    var app = "a call app"
    var screen = true, system = true, mic = true
    var maxMinutes = 240.0

    init(_ argv: [String]) {
        var it = argv.dropFirst().makeIterator()
        cmd = it.next() ?? ""
        while let a = it.next() {
            switch a {
            case "--out": out = it.next()
            case "--locale": locale = it.next()
            case "--who": who = it.next() ?? who
            case "--app": app = it.next() ?? app
            case "--no-screen": screen = false
            case "--no-system": system = false
            case "--no-mic": mic = false
            case "--max-minutes": maxMinutes = Double(it.next() ?? "") ?? maxMinutes
            default:
                if a.hasPrefix("-") { fail("unknown option \(a)") }
                file = a
            }
        }
    }
}

func micStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    default: return "not-asked"
    }
}

func check(_ a: Args) async {
    let loc = await speechLocale(a.locale)
    var installed = false
    if let l = loc { installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == l.identifier(.bcp47) } }
    printJSON(["speech": SpeechTranscriber.isAvailable, "locale": loc?.identifier(.bcp47) ?? "",
               "model_installed": installed, "screen": CGPreflightScreenCaptureAccess() ? "granted" : "not-granted",
               "mic": micStatus()])
}

func prop32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func bundleID(_ obj: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let v = cf else { return "" }
    return v.takeRetainedValue() as String
}

func isRecorder(_ pid: pid_t) -> Bool {
    if pid == getpid() { return true }
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
    return String(cString: buf).hasSuffix("/rami-rec")
}

// Processes other than Rami's own recorder that are taking audio input now
// (bundle ids). macOS 14.2+ lists audio clients per process; while Rami
// records, the mic is busy because of us, so only other users count.
func micUsers() -> [String]? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return nil }
    var out: [String] = []
    for id in ids {
        guard prop32(id, kAudioProcessPropertyIsRunningInput) == 1, let raw = prop32(id, kAudioProcessPropertyPID) else { continue }
        let pid = pid_t(bitPattern: raw)
        if isRecorder(pid) { continue }
        var bundle = bundleID(id)
        if bundle.isEmpty, let app = NSRunningApplication(processIdentifier: pid) { bundle = app.bundleIdentifier ?? "" }
        let name = bundle.isEmpty ? "pid \(pid)" : bundle
        if !SYSTEM_LISTENERS.contains(name) && !out.contains(name) { out.append(name) }
    }
    return out
}

func calls() {
    var apps: [String] = []
    var browser = false
    for app in NSWorkspace.shared.runningApplications {
        guard let id = app.bundleIdentifier else { continue }
        if let name = CALL_APPS[id], !apps.contains(name) { apps.append(name) }
        if BROWSERS.contains(id) { browser = true }
    }
    let users = micUsers()
    printJSON(["mic_busy": !(users ?? []).isEmpty, "mic_users": users ?? [], "per_process": users != nil,
               "apps": apps, "browser": browser])
}

func transcribe(_ a: Args) async {
    guard let path = a.file, let dir = a.out else { fail("usage: rami-rec transcribe FILE --out DIR") }
    guard let loc = await speechLocale(a.locale) else { fail("speech is not available for this language") }
    do {
        let out = try Out(dir: URL(fileURLWithPath: dir))
        let src = try await Source(who: a.who, out: out, locale: loc, keepAudio: false)
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        out.state = "transcribing"
        // Reading at the end of a file throws rather than returning no frames.
        while f.framePosition < f.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 16384) else { break }
            try f.read(into: buf)
            if buf.frameLength == 0 { break }
            src.feed(buf)
        }
        await src.finish()
        out.state = "done"
        out.flushLive()
        out.finish(["mode": "transcribe"])
    } catch {
        fail("transcribe: \(error.localizedDescription)")
    }
}

func record(_ a: Args) async {
    guard let dir = a.out else { fail("usage: rami-rec record --out DIR") }
    let out: Out
    do { out = try Out(dir: URL(fileURLWithPath: dir)) } catch { fail("cannot write to \(dir): \(error.localizedDescription)") }
    let rec = Recorder(out: out)
    // Kept in a global: a local timer is cancelled when this function returns,
    // and live.json (timer, levels, heard) would stop updating.
    liveTimer = DispatchSource.makeTimerSource(queue: .main)
    liveTimer?.schedule(deadline: .now(), repeating: LIVE_INTERVAL)
    liveTimer?.setEventHandler { out.flushLive() }
    liveTimer?.resume()

    var stopping = false
    let stopNow: @Sendable () -> Void = {
        DispatchQueue.main.async {
            if stopping { return }
            stopping = true
            Task {
                await rec.stop()
                out.state = "done"
                out.flushLive()
                var files: [String] = []
                for n in ["audio-you.m4a", "audio-them.m4a", "screen.mov"]
                where FileManager.default.fileExists(atPath: out.dir.appendingPathComponent(n).path) { files.append(n) }
                out.finish(["mode": "record", "files": files])
                exit(0)
            }
        }
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { stopNow() }
        src.resume()
        signalSources.append(src)
    }

    guard let loc = await speechLocale(a.locale) else {
        out.note("speech is not available for this language; recording without a transcript")
        return await startCapture(rec, a, nil, stopNow)
    }
    await startCapture(rec, a, loc, stopNow)
}

var signalSources: [DispatchSourceSignal] = []
var liveTimer: DispatchSourceTimer?

func startCapture(_ rec: Recorder, _ a: Args, _ loc: Locale?, _ stopNow: @escaping @Sendable () -> Void) async {
    let out = rec.out
    if let l = loc {
        do {
            if a.mic { rec.you = try await Source(who: "you", out: out, locale: l, keepAudio: true) }
            if a.system { rec.them = try await Source(who: "them", out: out, locale: l, keepAudio: true) }
        } catch {
            out.note("speech model: \(error.localizedDescription)")
        }
    }
    if a.mic {
        do { try rec.startMic() } catch { out.note("microphone: \(error.localizedDescription)") }
    }
    if a.screen || a.system {
        do { try await rec.startScreen(video: a.screen, audio: a.system) } catch {
            out.note("screen and system audio need Screen Recording permission (\(error.localizedDescription))")
        }
    }
    if rec.engine == nil && rec.stream == nil {
        out.note("nothing to record")
        out.state = "failed"
        out.flushLive()
        out.finish(["mode": "record", "files": []])
        exit(2)
    }
    out.state = "recording"
    out.flushLive()
    DispatchQueue.main.asyncAfter(deadline: .now() + a.maxMinutes * 60) {
        out.note("stopped after \(Int(a.maxMinutes)) minutes")
        stopNow()
    }
}

// A pop-up above every window, so the owner can say yes without opening the
// page. Not now, Esc, or no answer in 45 s means no.
func ask(_ a: Args) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Record this call?"
    alert.informativeText = "A call started in \(a.app). Rami records the screen, your mic and the call's audio on this Mac, " +
        "and links what is said to your tasks. Tell the others before you record."
    alert.addButton(withTitle: "Record")
    alert.addButton(withTitle: "Not now").keyEquivalent = "\u{1b}"
    alert.window.level = .floating
    Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in app.abortModal() }
    let yes = alert.runModal() == .alertFirstButtonReturn
    printJSON(["record": yes])
}

let args = Args(CommandLine.arguments)
if args.cmd == "ask" {
    ask(args)
    exit(0)
}
Task {
    switch args.cmd {
    case "check": await check(args); exit(0)
    case "calls": calls(); exit(0)
    case "transcribe": await transcribe(args); exit(0)
    case "record": await record(args)   // runs until a signal
    default: fail("usage: rami-rec check|calls|ask --app NAME|record --out DIR|transcribe FILE --out DIR")
    }
}
// A real AppKit main loop, not dispatchMain(): ScreenCaptureKit puts its
// recording indicator in the menu bar, which must happen on the main thread
// (dispatchMain parks that thread and runs main-queue work elsewhere).
// .prohibited: no Dock icon and no menu bar of our own.
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
