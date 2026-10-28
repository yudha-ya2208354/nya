import Foundation
import FoundationModels

enum Cfg {
    static var gate = true                       // confirm write/edit/bash
    static var pcc = false                       // false = on-device FM, true = Private Cloud Compute
    static var think: ContextOptions.ReasoningLevel? = nil   // PCC only: light/moderate/deep
    static var budget = 0.60                      // auto-compaction trigger, fraction of contextSize
    static var turnCap = 24                       // tool iterations the model may take per turn
    static var chat = true                        // small talk skips the tool schema entirely
    static var sys: String {
        """
        nya: terse terminal coding agent. cwd \(root).
        Call tools ONLY for what the user asked for. Greetings, opinions, feelings and questions about you are answered in plain text with no tool call.
        Never create, edit, or log to a file the user did not name. Never invent a task, and never report work you did not do.
        Before saying anything about code, look with read/grep — never guess file contents. edit > write. Relative paths ok.
        Never grep or read files to find the content of an attached image — it is already in front of you.
        Answer in under 120 words, no preamble, no markdown headings. Code blocks only when asked to.
        End with one line on what changed, or what you still need — unless you changed nothing, then just answer.
        """
    }
    static var softSys: String {
        """
        nya: warm tiny terminal sidekick. 1-3 short lines, no preamble, no markdown, one kaomoji is welcome.
        You have no tools here. Never invent file contents and never claim you did work. If the message really needs files or commands, say it got routed to chat by mistake and ask for the path.
        """
    }
    // every word must be conversational, else assume it is a task and keep the tools
    static let soft: Set<String> = [
        "hi", "hii", "hello", "hey", "heya", "hiya", "yo", "sup", "howdy", "hallo", "heyo",
        "how", "are", "you", "doing", "today", "ok", "okay", "k", "good", "great", "fine", "well", "bad",
        "nm", "hbu", "wbu", "thanks", "thank", "ty", "yw", "np", "sorry", "welcome",
        "lol", "lmao", "rofl", "wow", "wowza", "cool", "nice", "cute", "amazing", "sad", "angry", "tired",
        "i", "im", "am", "me", "my", "mine", "ur", "your", "is", "it", "this", "that", "so", "very", "really",
        "just", "too", "not", "no", "yes", "yeah", "yep", "nope", "and", "but", "or", "please", "pls",
        "who", "what", "can", "do", "sleep", "feel", "know", "think", "guess", "love", "hate",
        "fuck", "fucking", "shit", "wtf", "stupid", "dumb", "useless", "suck", "yay", "oops", "bye", "cya",
        "gtg", "hmm", "huh", "oh", "ah", "aha", "meh", "um", "erm", "anyway", "god", "man", "dude", "bro",
    ]
}

final class Brain {
    let on = SystemLanguageModel.default
    let pc = PrivateCloudComputeLanguageModel()
    let tools: [any Tool] = TOOLS
    var ses: LanguageModelSession
    var plain: LanguageModelSession
    var small: LanguageModelSession          // no tools, no schema — where small talk goes
    var window = 8_192, used = 0, gen = 0, reas = 0, turns = 0
    var imgs: [URL] = []

    init() {
        ses = Brain.mk(on, tools, Cfg.sys, nil)
        plain = Brain.mk(on, [], "", nil)
        small = Brain.mk(on, [], Cfg.softSys, nil)
    }

    static func mk<M: LanguageModel>(_ m: M, _ t: [any Tool], _ ins: String, _ tr: Transcript?) -> LanguageModelSession {
        if let tr { LanguageModelSession(model: m, tools: t, transcript: tr) }
        else { LanguageModelSession(model: m, tools: t, instructions: ins) }
    }

    func route(_ toPCC: Bool) async {
        if toPCC, !pc.isAvailable { Cfg.pcc = false; Pen.shared.warn("PCC unavailable: \(pc.availability)"); return }
        let tr = ses.transcript
        Cfg.pcc = toPCC
        await rebuild(tr)
        Pen.shared.ohai("\(toPCC ? "pcc" : "fm") ready · window \(window) tok · \(toPCC ? "reasoning ✓" : "on-device")")
    }

    func rebuild(_ tr: Transcript? = nil) async {
        if Cfg.pcc {
            ses = Brain.mk(pc, tools, Cfg.sys, tr); plain = Brain.mk(pc, [], "", nil)
            small = Brain.mk(pc, [], Cfg.softSys, nil)
            window = (try? await pc.contextSize) ?? window
        } else {
            ses = Brain.mk(on, tools, Cfg.sys, tr); plain = Brain.mk(on, [], "", nil)
            small = Brain.mk(on, [], Cfg.softSys, nil)
            window = on.contextSize
        }
    }

    // ── one turn: FM/PCC runs the tool loop itself, so no hand-rolled agent loop
    func turn(_ text: String, retried: Bool = false) async {
        let ctx = ContextOptions(reasoningLevel: Cfg.pcc ? Cfg.think : nil)
        var printed = "", live = false
        Pen.shared.raw("")
        do {
            let chat = Cfg.chat && imgs.isEmpty && isChatty(text)
            if chat { Pen.shared.line("  " + C.t(C.ash, "⌒ small talk · no tools")) }
            let s = chat ? small : ses
            let stream: LanguageModelSession.ResponseStream<String>
            if imgs.isEmpty {
                stream = s.streamResponse(to: text, options: GenerationOptions(), contextOptions: ctx)
            } else {
                let urls = imgs; imgs = []
                stream = s.streamResponse(options: GenerationOptions(), contextOptions: ctx) {
                    for u in urls { Attachment(imageURL: u).label(rel(u.lastPathComponent)) }
                    text
                }
            }
            for try await snap in stream {
                if App.hit { break }
                let calls = snap.transcriptEntries.filter { if case .toolCalls = $0 { return true }; return false }.count
                if calls > Cfg.turnCap {
                    Pen.shared.line()
                    Pen.shared.warn("stopped after \(Cfg.turnCap) tool calls — /compress or narrow the ask")
                    break
                }
                let c = snap.content
                if c.isEmpty { continue }
                if !live { live = true; Pen.shared.raw(C.t(C.bubble, " ᵔᵕᵔ ") + " ") }
                if c.hasPrefix(printed) {
                    Pen.shared.raw(String(c.dropFirst(printed.count)))
                } else {
                    Pen.shared.raw("\r" + C.clr + C.t(C.bubble, " ᵔᵕᵔ ") + " " + c)   // segment rewritten
                }
                printed = c
                if !chat { used = snap.usage.input.totalTokenCount }   // small talk never loads the tool session, so don't fake its pressure
                gen = snap.usage.output.totalTokenCount
                reas = snap.usage.output.reasoningTokenCount
            }
            if App.hit { Pen.shared.line(); Pen.shared.warn("interrupted") }
            else if live { Pen.shared.line() }
            else { Pen.shared.line("  " + C.t(C.ash, "(no output)")) }
        } catch {
            if isOverflow(error), !retried {
                Pen.shared.line()
                await compact("overflow")
                await turn(text, retried: true)
                return
            }
            if Cfg.pcc, !retried {
                Pen.shared.line()
                let (dom, code) = Brain.root(error)
                Pen.shared.warn("pcc unavailable (\(dom.split(separator: ".").last ?? "?") #\(code)) — retrying on-device")
                await route(false)
                await turn(text, retried: true)
                return
            }
            Pen.shared.line()
            fail(error)
        }
        turns += 1
        if Double(used) > Double(window) * Cfg.budget { await compact("auto") }
    }

    /// FM reports a mid-turn overflow as a plain inference failure, not the typed case
    static func isOverflow(_ e: any Error) -> Bool {
        if let l = e as? LanguageModelError, case .contextSizeExceeded = l { return true }
        let d = "\(e)"
        return d.contains("maximum allowed") || d.contains("Retained context") || d.contains("contextSizeExceeded")
    }
    func isOverflow(_ e: any Error) -> Bool { Brain.isOverflow(e) }

    /// Apple hides the real cause under NSMultipleUnderlyingErrorsKey
    static func root(_ e: any Error) -> (String, Int) {
        let n = e as NSError
        if let u = n.userInfo["NSMultipleUnderlyingErrorsKey"] as? [Any] {
            for x in u { if let m = x as? NSError, m.domain.contains("ModelManager") { return (m.domain, m.code) } }
        }
        return (n.domain, n.code)
    }

    func fail(_ e: any Error) {
        let d = "\(e)"
        if let x = e as? LanguageModelError {
            switch x {
            case .contextSizeExceeded(let c): Pen.shared.warn("context full (\(c.tokenCount)/\(c.contextSize)) — /compress"); return
            case .refusal: Pen.shared.warn("model refused this request"); return
            case .guardrailViolation: Pen.shared.warn("blocked by Apple guardrails"); return
            case .rateLimited(let r): Pen.shared.warn("rate limited, retry \(r.resetDate.map { "after \($0)" } ?? "soon")"); return
            case .unsupportedTranscriptContent: Pen.shared.warn("this model can't use part of the transcript (an image?) — /clear to reset"); return
            case .unsupportedCapability(let c): Pen.shared.warn("\(c.debugDescription) — try /fm or drop /think"); return
            case .unsupportedGenerationGuide: Pen.shared.warn("guided generation not supported here"); return
            case .unsupportedLanguageOrLocale: Pen.shared.warn("model doesn't support this locale"); return
            case .timeout(let t): Pen.shared.warn("inference timed out: \(t.debugDescription)"); return
            @unknown default: break
            }
        }
        let (dom, code) = Brain.root(e)
        if dom.contains("ModelManager") {
            if code == 1046 {
                Pen.shared.warn("PCC refused (1046): this process lacks the Private Cloud Compute entitlement.")
                Pen.shared.line("     " + C.t(C.ash, "not a code bug — Apple gates it behind a requested capability + provisioning profile."))
                Pen.shared.line("     " + C.t(C.ash, "stay on /fm, or build a signed bundle: ./app.sh <codesign identity> <profile>"))
                return
            }
            Pen.shared.warn("model manager error \(code) — /fm to keep working on-device"); return
        }
        if d.contains("quota") { Pen.shared.warn("PCC quota hit — /fm to fall back on-device"); return }
        if d.contains("network") || d.contains("offline") { Pen.shared.warn("PCC unreachable — /fm for on-device"); return }
        Pen.shared.line("  " + C.t(C.coral, "✗ " + clip(d, 240)))
    }

    /// A single long turn can hold thousands of tokens of tool output that the model
    /// no longer needs verbatim. Keep its head lines, drop the rest.
    func shrink(_ e: Transcript.Entry) -> Transcript.Entry {
        guard case .toolOutput(let t) = e else { return e }
        guard case .text(let seg)? = t.segments.first, seg.content.count > 400 else { return e }
        let head = seg.content.split(separator: "\n").prefix(2).map(String.init).joined(separator: " ⏎ ")
        return .toolOutput(.init(id: t.id, toolName: t.toolName,
                                 segments: [.text(.init(id: seg.id, content: "[output trimmed] " + clip(head, 260)))]))
    }

    // ── summarize the head of the transcript, keep a clean tail
    func compact(_ why: String) async {
        let es = Array(ses.transcript)
        var cut = es.count - 1
        while cut > 0, !prompt(es[cut]) { cut -= 1 }
        if cut < 2 {
            let before = used
            var t = Transcript(); t.append(contentsOf: es.map(shrink))
            await rebuild(t)
            used = Cfg.pcc ? before / 2 : ((try? await on.tokenCount(for: Array(ses.transcript))) ?? before / 2)
            Pen.shared.ohai("trimmed past tool output \(before) → \(used) tok (\(why))")
            return
        }
        Pen.shared.tool("compact", why, "\(used)/\(window) tok")
        let notes = await whisper("Compress this coding-agent transcript into notes I can act on. Keep every file path, decision and reason, unresolved task, exact number. 120 words max.\n\n" + dump(Array(es[0 ..< cut])))
        var t = Transcript()
        t.append(.prompt(.init(segments: [.text(.init(content: "[earlier, \(cut) turns compressed]) \(notes)"))])))
        for e in es[cut...] { t.append(e) }
        await rebuild(t)
        used = Cfg.pcc ? used / 3 : ((try? await on.tokenCount(for: Array(ses.transcript))) ?? used / 3)
        Pen.shared.ohai("notes saved, window now \(used)/\(window)")
    }

    func whisper(_ p: String) async -> String {
        var o = ""
        do { for try await s in plain.streamResponse(to: p) { o = s.content } } catch { Pen.shared.warn("summary failed: \(error)") }
        return o
    }

    // ── persistence: chat-visible text only; tool plumbing is not worth replaying
    func chat() -> [(String, String)] {
        ses.transcript.compactMap { e -> (String, String)? in
            switch e {
            case .prompt(let p): return ("you", flat(p.segments))
            case .response(let r): return ("nya", flat(r.segments))
            default: return nil
            }
        }
    }

    func save(_ name: String) throws {
        let dir = home + "/.nya/sessions"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let arr = chat().map { ["r": $0.0, "t": $0.1] }
        try JSONSerialization.data(withJSONObject: arr).write(to: URL(fileURLWithPath: "\(dir)/\(name).json"))
        Pen.shared.ohai("saved \(dir)/\(name).json (\(arr.count) messages)")
    }

    func load(_ name: String) async throws {
        let url = URL(fileURLWithPath: home + "/.nya/sessions/\(name).json")
        guard let d = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: String]] else { throw App.x("no session \(name)") }
        var t = Transcript()
        for m in d {
            let seg = [Transcript.Segment.text(.init(content: m["t"] ?? ""))]
            t.append(m["r"] == "nya" ? .response(.init(segments: seg)) : .prompt(.init(segments: seg)))
        }
        await rebuild(t)
        Pen.shared.ohai("resumed \(name) (\(d.count) messages)")
    }

    /// where the fixed tokens go: instructions, tool schemas, history
    func overhead() async -> String {
        if Cfg.pcc { return "token counts are on-device only" }
        let i = (try? await on.tokenCount(for: Instructions(Cfg.sys))) ?? 0
        let t = (try? await on.tokenCount(for: tools)) ?? 0
        let h = (try? await on.tokenCount(for: Array(ses.transcript))) ?? 0
        return "fixed cost — instructions \(i) + tools \(t) = \(i + t) tok, history \(h) of \(window)"
    }

    func hud() -> String {
        let pct = window > 0 ? Int(Double(used) / Double(window) * 100) : 0
        let model = Cfg.pcc ? (Cfg.think.map { "pcc/\(thinkName($0))" } ?? "pcc") : "fm"
        let c = pct > 85 ? C.coral : pct > 60 ? C.gold : C.mint
        return "  " + C.t(C.ash, "╰─") + " " + C.t(C.lilac, model) + " "
            + C.t(C.ash, "♡ \(used)/\(window)") + C.t(c, " \(pct)%") + " "
            + C.t(C.ash, "↑\(gen) tok · \(Cfg.gate ? "gate on" : "YOLO") · \(turns) turns")
    }
}

func thinkName(_ l: ContextOptions.ReasoningLevel) -> String {
    switch l { case .light: return "light"; case .moderate: return "med"; case .deep: return "deep"; case .custom(let s): return s
    @unknown default: return "?" }
}

func prompt(_ e: Transcript.Entry) -> Bool { if case .prompt = e { return true }; return false }

func isChatty(_ s: String) -> Bool {
    let ws = s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    return !ws.isEmpty && ws.count <= 6 && ws.allSatisfy { Cfg.soft.contains($0) }
}

func flat(_ segs: [Transcript.Segment]) -> String {
    segs.map { s -> String in
        switch s {
        case .text(let t): return t.content
        case .structure(let x): return x.content.debugDescription
        case .attachment(let a): return a.label ?? "<image>"
        @unknown default: return ""
        }
    }.joined(separator: " ")
}

func dump(_ es: [Transcript.Entry]) -> String {
    var o = ""
    for e in es {
        switch e {
        case .prompt(let p): o += "user: " + flat(p.segments) + "\n"
        case .response(let r): o += "nya: " + flat(r.segments) + "\n"
        case .toolCalls(let tc): for c in tc { o += "→ \(c.toolName) \(clip(c.arguments.jsonString, 100))\n" }
        case .toolOutput(let t): o += "← \(clip(flat(t.segments), 160))\n"
        case .reasoning, .instructions: break
        @unknown default: break
        }
    }
    return capped(o, 9_000)
}
