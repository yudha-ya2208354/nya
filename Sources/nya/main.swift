import Foundation
import FoundationModels

enum App {
    static var hit = false
    struct E: Error { let m: String }
    static func x(_ s: String) -> Error { E(m: s) }
}

let pen = Pen.shared
let b = Brain()
signal(SIGINT) { _ in App.hit = true }

func banner() {
    pen.line(C.t(C.rose, """
         ╭──────────────────────────────────────────╮
         │   /\\_/\\    n y a   ♡   hacker harness    │
         │  ( o.o )   Apple FoundationModels        │
         │   > ^ <    + Private Cloud Compute       │
         ╰──────────────────────────────────────────╯
         """))
    pen.line("  " + C.t(C.ash, "on-device FM for free speed · PCC for big reasoning · \(TOOLS.count) tools, loop run by the model itself"))
    pen.line("  " + C.t(C.ash, "/h for commands · Ctrl-C interrupts a turn · everything stays on this machine unless you /pcc"))
}

func help() {
    let rows: [(String, String)] = [
        ("/m  /fm  /pcc", "switch brain — fm is local & free, pcc is bigger + reasons"),
        ("/think l|m|d", "PCC reasoning level (tokens ↑ with depth)"),
        ("/gate  /yolo", "confirm write/edit/bash, or run everything"),
        ("/chat", "small talk answered without loading the 6 tool schemas"),
        ("/img <path>", "attach an image to your next message (both models see)"),
        ("/compress  /c", "fold old turns into notes (auto at \(Int(Cfg.budget * 100))% window)"),
        ("/budget <0-1>", "auto-compaction threshold"),
        ("/clear", "fresh transcript, keep this chat's files"),
        ("/save <n> /load <n> /ls", "session JSON in ~/.nya/sessions"),
        ("/tools", "list the tool surface"),
        ("/status", "model availability + quota"),
    ]
    for r in rows { pen.line("  " + C.t(C.mint, r.0.padding(toLength: 24, withPad: " ", startingAt: 0)) + C.t(C.ash, r.1)) }
    pen.line("  " + C.t(C.ash, "end a line with \\ for multiline input"))
}

func status() {
    pen.line("  " + C.t(C.lilac, "fm  ") + C.t(C.ash, "\(on1())"))
    let q = String("\(b.pc.quotaUsage.status)".prefix { $0 != "(" })
    pen.line("  " + C.t(C.bubble, "pcc ") + C.t(C.ash, "\(b.pc.availability) · quota \(q)"))
    pen.line("  " + C.t(C.mint, "now ") + C.t(C.ash, "\(Cfg.pcc ? "pcc" : "fm") · window \(b.window) · used \(b.used) (\(b.gen) generated, \(b.reas) reasoning)"))
}
func on1() -> String { "\(SystemLanguageModel.default.availability)" }

func tools() {
    for t in TOOLS { pen.line("  " + C.t(C.lilac, t.name.padding(toLength: 7, withPad: " ", startingAt: 0)) + C.t(C.ash, clip(t.description, 90))) }
}

func cmd(_ s: String) async -> Bool {
    let f = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
    let c = f[0], a = f.count > 1 ? f[1].trimmingCharacters(in: .whitespaces) : ""
    switch c {
    case "/q", "/quit", "/exit", "/bye": return true
    case "/h", "/help", "/?": help()
    case "/fm": await b.route(false)
    case "/pcc", "/cloud": await b.route(true)
    case "/m", "/model": await b.route(!Cfg.pcc)
    case "/think":
        switch a { case "l", "light": Cfg.think = .light; case "m", "med", "moderate": Cfg.think = .moderate
        case "d", "deep": Cfg.think = .deep; default: Cfg.think = nil }
        pen.ohai("reasoning: \(Cfg.think.map { thinkName($0) } ?? "off") — pcc only")
    case "/gate": Cfg.gate = true; Gate.always.removeAll(); pen.ohai("confirming write/edit/bash again")
    case "/chat": Cfg.chat.toggle(); pen.ohai("small talk bypasses tools: \(Cfg.chat ? "on" : "off")")
    case "/yolo": Cfg.gate = false; pen.warn("YOLO — the model can write and run anything in \(root)")
    case "/budget": if let d = Double(a), d > 0.05, d <= 0.95 { Cfg.budget = d }; pen.ohai("compact at \(Int(Cfg.budget * 100))% of window")
    case "/compress", "/c": await b.compact("manual")
    case "/clear": await b.rebuild(nil); b.used = 0; pen.ohai("transcript cleared")
    case "/tools": tools()
    case "/status": status(); pen.line("  " + C.t(C.ash, await b.overhead()))
    case "/img":
        let p = abs(a)
        if a.isEmpty || !FileManager.default.fileExists(atPath: p) { pen.warn("usage: /img path/to.png") }
        else { b.imgs.append(URL(fileURLWithPath: p)); pen.ohai("attached \(rel(p)) (\(b.imgs.count) pending)") }
    case "/save": do { try b.save(a.isEmpty ? "last" : a) } catch { pen.warn("\(error)") }
    case "/load": do { try await b.load(a.isEmpty ? "last" : a) } catch { pen.warn("\(error)") }
    case "/ls":
        let dir = home + "/.nya/sessions"
        let fs = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        pen.line(fs.isEmpty ? "  " + C.t(C.ash, "no saved sessions") : fs.sorted().map { "  " + C.t(C.mint, $0) }.joined(separator: "\n"))
    default: pen.warn("unknown \(c) — /h")
    }
    return false
}

banner()
await b.rebuild()
pen.line(b.hud())

while true {
    App.hit = false
    pen.raw("\n" + C.t(C.rose, "♡ nya ") + C.t(C.ash, "\(Cfg.pcc ? "☁" : "⌒")> "))
    guard var text = readLine() else { break }
    if text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    if text.hasPrefix("/") { if await cmd(text.trimmingCharacters(in: .whitespaces)) { break }; pen.line(b.hud()); continue }
    while text.hasSuffix("\\") { guard let more = readLine() else { break }; text = String(text.dropLast()) + "\n" + more }
    await b.turn(text)
    pen.line(b.hud())
}
pen.line("  " + C.t(C.lilac, "(^_^)/  bye — transcript not saved. /save <name> next time"))
