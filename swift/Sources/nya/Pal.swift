import Foundation
import Darwin

// pastel 256-color palette
enum C {
    static let off = "\u{1B}[0m", dim = "\u{1B}[2m", bold = "\u{1B}[1m", it = "\u{1B}[3m", clr = "\u{1B}[K"
    static let rose = 218, bubble = 205, mint = 122, lilac = 183, gold = 229, sky = 159, ash = 245, coral = 203, ice = 117
    static func t(_ n: Int, _ s: String) -> String { "\u{1B}[38;5;\(n)m\(s)\(off)" }
    static func cols() -> Int {
        var ws = winsize()
        if ioctl(1, UInt(TIOCGWINSZ), &ws) == 0, Int(ws.ws_col) > 0 { return Int(ws.ws_col) }
        return 80
    }
}

// serialized stdout — tool calls run concurrently and would otherwise interleave
final class Pen: @unchecked Sendable {
    static let shared = Pen()
    private let lock = NSLock()
    func raw(_ s: String) { lock.lock(); FileHandle.standardOutput.write(Data(s.utf8)); lock.unlock() }
    func line(_ s: String = "") { raw(s + "\n") }
    func flush() {}
}

extension Pen {
    // one-line tool header:  ♡ read  path · 42 lines
    func tool(_ name: String, _ arg: String, _ note: String = "", bad: Bool = false) {
        let head = bad ? "✗" : "♡"
        let col = bad ? C.coral : C.lilac
        var s = "  " + C.t(col, head) + " " + C.t(col, C.bold + name + C.off)
        if !arg.isEmpty { s += " " + C.t(C.rose, arg) }
        if !note.isEmpty { s += " " + C.t(C.ash, "· " + note) }
        line(s)
    }
    // dim continuation lines under a tool header
    func belly(_ text: String, max: Int = 6) {
        let ls = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for l in ls.prefix(max) where !l.trimmingCharacters(in: .whitespaces).isEmpty {
            line("     " + C.t(C.ash, "│") + " " + C.t(C.ash, clip(l, 160)))
        }
        if ls.count > max { line("     " + C.t(C.ash, "│ …\(ls.count - max) more")) }
    }
    func warn(_ s: String) { line("  " + C.t(C.gold, "⚠ " + s)) }
    func ohai(_ s: String) { line("  " + C.t(C.mint, s)) }
}

// single keypress without disturbing the shell's own line editing
func key(_ q: String) -> Character {
    var old = termios()
    guard tcgetattr(0, &old) == 0 else {
        Pen.shared.raw(q)
        Pen.shared.line(C.t(C.coral, "n") + " " + C.t(C.ash, "(stdin is not a terminal — /yolo to run without a tty)"))
        return "n"                       // fail closed: no tty means nobody is there to say yes
    }
    var raw = old
    raw.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
    tcsetattr(0, TCSANOW, &raw)
    Pen.shared.raw(q)
    let c = fgetc(stdin) // stdio, so a later readLine() can't lose buffered bytes
    tcsetattr(0, TCSANOW, &old)
    let ch: Character = c >= 0 ? Character(UnicodeScalar(UInt8(c))) : "\u{03}"
    if ch != "\u{03}", ch != "\n", ch != "\r" { Pen.shared.raw(String(ch)) }   // leave the answer on screen: audit trail
    Pen.shared.line()
    return ch
}

// argv-exact execution (no shell string built from model output except bash tool) -> merged, capped
@discardableResult
func shell(_ argv: [String], dir: String = FileManager.default.currentDirectoryPath, ms: Int = 30_000) -> String {
    guard !argv.isEmpty else { return "" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    p.currentDirectoryPath = dir
    let path = NSTemporaryDirectory() + "nya-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let fh = FileHandle(forWritingAtPath: path) else { return "(no tmpfile)" }
    p.standardOutput = fh; p.standardError = fh
    do { try p.run() } catch { return "(spawn failed: \(error.localizedDescription))" }
    let deadline = Date().addingTimeInterval(Double(ms) / 1000)
    while p.isRunning, Date() < deadline { usleep(15_000) }
    var timedOut = false
    if p.isRunning { p.terminate(); timedOut = true }
    fh.closeFile()
    let out = (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    try? FileManager.default.removeItem(atPath: path)
    return timedOut ? out + "\n[killed: over \(ms / 1000)s]" : out
}

func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "…" }
