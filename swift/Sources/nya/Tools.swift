import Foundation
import FoundationModels

// ─────────────────────────────────────────────────────────────
// Macro-free tool plumbing. Xcode's FoundationModelsMacros plugin isn't
// installed here, so @Generable can't expand. Instead every tool shares ONE
// argument type (GeneratedContent) and hand-builds its GenerationSchema from a
// terse spec string — nanocode's micro-schema, native to FM.
//   "name|description|arg:type:hint"   type: s|string, i|int, trailing ? = optional
// ─────────────────────────────────────────────────────────────

extension GeneratedContent {
    subscript(k: String) -> GeneratedContent? {
        if case .structure(let p, _) = kind { return p[k] }
        return nil
    }
    var str: String? { switch kind { case .string(let s): return s; case .number(let d): return String(d); case .bool(let b): return b ? "true" : "false"; default: return nil } }
    var int: Int? { switch kind { case .number(let d): return Int(d); case .string(let s): return Int(s); default: return nil } }
    var boo: Bool? { if case .bool(let b) = kind { return b }; return nil }
}

struct Args {
    let c: GeneratedContent
    var order: [String] = []   // declared arg order, so the preview shows the primary one
    func s(_ k: String, _ d: String = "") -> String { c[k]?.str ?? d }
    func so(_ k: String) -> String? { c[k]?.str }
    func i(_ k: String, _ d: Int = 0) -> Int { c[k]?.int ?? d }
    func io(_ k: String) -> Int? { c[k]?.int }
    /// one-line preview for the TUI: primary string argument
    var preview: String {
        for k in order { if let v = c[k]?.str?.split(separator: "\n").first { return clip(String(v), 60) } }
        if case .structure(_, let keys) = c.kind, let k = keys.first, let v = c[k]?.str { return clip(v, 60) }
        return clip(c.jsonString, 60)
    }
}

enum Gate {
    static var always = Set<String>()
    static func allow(_ tool: String, _ preview: String) -> Bool {
        if !Cfg.gate || always.contains(tool) { return true }
        let q = "\n  " + C.t(C.gold, "⚠ \(tool)") + " " + C.t(C.ash, preview)
            + "\n  " + C.t(C.mint, "y") + "es " + C.t(C.coral, "n") + "o " + C.t(C.sky, "a") + "lways → "
        while true {
            switch key(q) {
            case "y", "Y", "\n", " ": return true
            case "a", "A": always.insert(tool); Pen.shared.ohai("auto-approved \(tool) for this session"); return true
            default: return false
            }
        }
    }
}

var repeatCount: [String: Int] = [:]

struct Fn: Tool {
    typealias Output = String
    typealias Arguments = GeneratedContent

    let id: (name: String, desc: String)
    let spec: [(name: String, type: String, opt: Bool, hint: String)]
    let risky: Bool
    let body: (Args) async throws -> String

    init(_ sig: String, risky: Bool = false, _ body: @escaping (Args) async throws -> String) {
        let parts = sig.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        id = (parts[0], parts.count > 1 ? parts[1] : "")
        spec = (parts.count > 2 ? parts[2] : "").split(separator: ",").map { raw -> (String, String, Bool, String) in
            let f = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let ty = f.count > 1 ? f[1] : "s"
            return (f[0], ty.hasSuffix("?") ? String(ty.dropLast()) : ty, ty.hasSuffix("?"), f.count > 2 ? f[2] : "")
        }
        self.risky = risky
        self.body = body
    }

    var name: String { id.name }
    var description: String { id.desc }
    var parameters: GenerationSchema {
        GenerationSchema(type: GeneratedContent.self, description: id.desc, properties: spec.map { a in
            switch (a.type, a.opt) {
            case ("i", false): return GenerationSchema.Property(name: a.name, description: a.hint, type: Int.self)
            case ("i", true): return GenerationSchema.Property(name: a.name, description: a.hint, type: Int?.self)
            case (_, false): return GenerationSchema.Property(name: a.name, description: a.hint, type: String.self)
            case (_, true): return GenerationSchema.Property(name: a.name, description: a.hint, type: String?.self)
            }
        })
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let a = Args(c: arguments, order: spec.map(\.name))
        if risky, !Gate.allow(id.name, a.preview) {
            Pen.shared.tool(id.name, a.preview, "declined by user", bad: true)
            return "The user declined this action. Do not retry it; ask what they would prefer instead."
        }
        let key = "\(id.name)|\(a.preview)"
        let out = try await body(a)
        let bad = ["not found", "no such file", "failed", "ambiguous", "declined", "no matches", "already applied"]
        if bad.contains(where: out.contains) {
            repeatCount[key, default: 0] += 1
            if repeatCount[key]! >= 2 {
                Pen.shared.tool(id.name, a.preview, "repeated failure — telling model to stop", bad: true)
                return "\(out)\nYou have failed this exact call \(repeatCount[key]!) times. Stop retrying it; change approach or ask the user."
            }
        } else { repeatCount[key] = 0 }
        Pen.shared.tool(id.name, a.preview, firstLine(out))
        return out
    }
}

func firstLine(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return "empty" }
    let n = t.split(separator: "\n").count
    return n == 1 ? clip(t, 44) : "\(n) lines"
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let root = FileManager.default.currentDirectoryPath

func abs(_ p: String) -> String {
    if p.hasPrefix("~") { return home + p.dropFirst() }
    if p.hasPrefix("/") { return p }
    return root + "/" + p
}
func rel(_ p: String) -> String { p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p }

// cap what enters history — the single biggest token saving
func capped(_ s: String, _ n: Int = 2_500) -> String {
    var lines = s.components(separatedBy: "\n")
    var out: [String] = [], total = 0
    var run = 0, last = ""
    for l in lines {
        if l == last { run += 1; if run > 3 { last = l; continue } } else { run = 0; last = l }
        total += l.count + 1
        if total > n { out.append("[…truncated at \(n) chars — use offset/limit to page]"); break }
        out.append(l)
    }
    lines = out
    return lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
}

let TOOLS: [Fn] = [
    Fn("read|Read a file as line-numbered text. Use offset/limit to page.|path:s:file,offset:i?:first line,limit:i?:lines to read") { a in
        let p = abs(a.s("path"))
        guard let txt = try? String(contentsOfFile: p, encoding: .utf8) else { return "no such file or unreadable text: \(rel(p))" }
        let ls = txt.components(separatedBy: "\n")
        let from = max(1, a.i("offset", 1)), to = min(ls.count, from + max(1, a.i("limit", 80)) - 1)
        var o = ""
        for i in from...max(from, to) { o += String(format: "%4d\t%@\n", i, ls[i - 1]) }
        if to < ls.count { o += "… \(ls.count - to) more lines (offset:\(to + 1))\n" }
        return o
    },

    Fn("write|Create or overwrite a file. Prefer edit for small changes.|path:s:file,content:s:full text", risky: true) { a in
        let p = abs(a.s("path"))
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: p).deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try a.s("content").write(toFile: p, atomically: true, encoding: .utf8) } catch { return "write failed: \(error)" }
        return "wrote \(rel(p)) (\(a.s("content").count) chars)"
    },

    Fn("edit|Replace old with new in a file. old must be unique unless all.|path:s:file,old:s:exact text to find,new:s:replacement,all:s?:true = every match", risky: true) { a in
        let p = abs(a.s("path"))
        guard var txt = try? String(contentsOfFile: p, encoding: .utf8) else { return "no such file: \(rel(p))" }
        let old = a.s("old"), new = a.s("new"), all = a.so("all")?.lowercased().starts(with: "t") == true
        let n = txt.components(separatedBy: old).count - 1
        if n == 0 {
            if !new.isEmpty, txt.contains(new) { return "already applied — \(rel(p)) already contains the new text. Nothing to do; move on." }
            return "not found: \(clip(old, 80)). Re-read the file and copy the exact text including whitespace."
        }
        if n > 1, !all { return "ambiguous: \(old.prefix(60)) matches \(n) times. Add more surrounding context, or pass all:true." }
        txt = all ? txt.replacingOccurrences(of: old, with: new) : txt.replacing(key: old, with: new)
        do { try txt.write(toFile: p, atomically: true, encoding: .utf8) } catch { return "write failed: \(error)" }
        return "edited \(rel(p)) — \(all ? n : 1) site(s)"
    },

    Fn("grep|Regex search over files. Returns path:line:text.|pattern:s:regex,path:s?:dir (default .),fi:s?:filename filter like *.swift") { a in
        if a.s("pattern").isEmpty { return "failed: grep needs a pattern" }
        if !FileManager.default.fileExists(atPath: abs(a.s("path", "."))) { return "no such file or directory: \(a.s("path", "."))" }
        var argv = ["/usr/bin/grep", "-rnI", "-E", a.s("pattern")]
        if let f = a.so("fi") { argv += ["--include", f] }
        argv += [abs(a.s("path", "."))]
        let out = shell(argv, ms: 20_000)
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "no matches for \(a.s("pattern"))" }
        let hits = out.components(separatedBy: "\n")
        return capped(hits.prefix(60).map { rel($0) }.joined(separator: "\n"), 4_000) + (hits.count > 60 ? "\n… \(hits.count - 60) more" : "")
    },

    Fn("glob|Files matching a name pattern, newest first.|pattern:s:like *.swift,path:s?:dir (default .)") { a in
        var pat = a.s("pattern"), dir = a.s("path", ".")
        if pat.isEmpty { pat = "*" }
        if pat.contains("/") { // a pattern with slashes is a path: split it, -name can never match one
            dir = (dir as NSString).appendingPathComponent((pat as NSString).deletingLastPathComponent)
            pat = (pat as NSString).lastPathComponent
        }
        if !FileManager.default.fileExists(atPath: abs(dir)) { return "no such file or directory: \(dir)" }
        let out = shell(["/usr/bin/find", abs(dir), "-name", pat,
                         "-not", "-path", "*/.git/*", "-not", "-path", "*/node_modules/*", "-type", "f"], ms: 15_000)
        let fs = out.components(separatedBy: "\n").filter { !$0.isEmpty }.map(rel)
        if fs.isEmpty { return "no files match \(a.s("pattern"))" }
        let sorted = fs.sorted { (m($0), $0) < (m($1), $1) }
        return sorted.prefix(120).enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: "\n")
            + (sorted.count > 120 ? "\n… \(sorted.count - 120) more" : "")
    },

    Fn("bash|Run a shell command; stdout+stderr merged, 30s default. For tests, git, builds.|command:s:shell,timeout:i?:seconds", risky: true) { a in
        shell(["/bin/sh", "-c", a.s("command")], ms: max(1, a.i("timeout", 30)) * 1000)
    },
]

func m(_ p: String) -> Date {
    (try? FileManager.default.attributesOfItem(atPath: abs(p))[.modificationDate] as? Date) ?? .distantPast
}

// replace only the first occurrence
extension String {
    func replacing(key: String, with value: String) -> String {
        guard let r = range(of: key) else { return self }
        return replacingSubrange(r, with: value)
    }
    func replacingSubrange(_ r: Range<String.Index>, with value: String) -> String {
        var c = self; c.replaceSubrange(r, with: value); return c
    }
}
