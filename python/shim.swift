// nya shim — FoundationModels has no Objective-C surface (no headers, no classes),
// so Python cannot reach it directly. This is the smallest possible bridge: it reads
// one JSON object per line on stdin, answers with JSON objects on stdout, and owns
// nothing except the model call. Tools, approval, budget and history live in nya.py.
//
// build: swiftc -swift-version 5 -target arm64-apple-macosx27.0 shim.swift -o shim
import Foundation
import FoundationModels

let out = FileHandle.standardOutput
func emit(_ o: [String: Any]) {
    let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    out.write(d + Data("\n".utf8))
}

let fm = SystemLanguageModel.default
let pc = PrivateCloudComputeLanguageModel()

// ── schema assembled at runtime from a JSON spec (DynamicGenerationSchema is the only
//    way to build one without the @Generable macro, which ships only inside Xcode)
func dyn(_ p: [String: Any]) -> DynamicGenerationSchema.Property? {
    guard let n = p["n"] as? String else { return nil }
    let d = p["d"] as? String
    let opt = (p["o"] as? Bool) ?? false
    let s: DynamicGenerationSchema
    switch p["t"] as? String ?? "s" {
    case "i": s = DynamicGenerationSchema(type: Int.self)
    case "b": s = DynamicGenerationSchema(type: Bool.self)
    case "e": s = DynamicGenerationSchema(name: n, description: d, anyOf: (p["c"] as? [String]) ?? [])
    default: s = DynamicGenerationSchema(type: String.self)
    }
    return DynamicGenerationSchema.Property(name: n, description: d, schema: s, isOptional: opt)
}

func schema(_ spec: [String: Any]?) -> GenerationSchema? {
    guard let spec, let ps = spec["props"] as? [[String: Any]] else { return nil }
    let props = ps.compactMap(dyn)
    let root = DynamicGenerationSchema(name: spec["name"] as? String ?? "step",
                                       description: spec["desc"] as? String, properties: props)
    return try? GenerationSchema(root: root, dependencies: [])
}

// ── history: you/nya are real transcript entries; tool results come back as prompts,
//    because schema-driven calling is not the session's native tool loop
func transcript(_ msgs: [[String: Any]]) -> Transcript {
    var t = Transcript()
    for m in msgs {
        let role = m["r"] as? String ?? "you", txt = m["t"] as? String ?? ""
        let body = role == "tool" ? "[tool result] " + txt : txt
        let seg = Transcript.Segment.text(.init(content: body))
        if role == "nya" { t.append(.response(.init(segments: [seg]))) }
        else { t.append(.prompt(.init(segments: [seg]))) }
    }
    return t
}

func usage(_ u: LanguageModelSession.Usage) -> [String: Int] {
    ["in": u.input.totalTokenCount, "out": u.output.totalTokenCount, "reas": u.output.reasoningTokenCount]
}

// a model failure has to be classified here — Python cannot see the typed error
func explain(_ e: any Error) -> [String: Any] {
    let d = String(describing: e)
    var dom = "", code = -1
    let ns = e as? NSError
    dom = ns?.domain ?? ""
    code = ns?.code ?? -1
    if let multi = ns?.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError], let f = multi.first {
        dom = f.domain; code = f.code
    }
    let over = d.contains("maximum allowed") || d.contains("Retained context") || d.contains("contextSizeExceeded")
    if case LanguageModelError.contextSizeExceeded = e { return ["error": d, "dom": dom, "code": code, "overflow": true, "pcc_down": false] }
    let pccDown = dom.contains("ModelManager") || d.contains("PrivateCloudCompute") || code == 1046
    return ["error": d, "dom": dom, "code": code, "overflow": over, "pcc_down": pccDown]
}

func ask(_ r: [String: Any]) async {
    let ins = r["instructions"] as? String ?? ""
    let msgs = (r["messages"] as? [[String: Any]]) ?? []
    let wantPCC = (r["pcc"] as? Bool) ?? false
    let think = r["think"] as? String ?? ""
    let imgs = (r["images"] as? [String]) ?? []
    let ctx = ContextOptions(reasoningLevel: wantPCC && ["light", "moderate", "deep"].contains(think)
        ? (think == "light" ? .light : think == "deep" ? .deep : .moderate) : nil)
    let tr = transcript(msgs)
    let prompt = (r["prompt"] as? String) ?? ""
    let spec = r["schema"] as? [String: Any]

    // a session per call keeps the shim stateless; nya.py owns the conversation
    if let s = schema(spec) {
        let ses = wantPCC ? LanguageModelSession(model: pc, tools: [], transcript: tr)
                          : LanguageModelSession(model: fm, tools: [], transcript: tr)
        var last = "", u: [String: Int] = [:]
        do {
            let stream = ses.streamResponse(schema: s, options: GenerationOptions(), contextOptions: ctx) {
                for p in imgs { Attachment(imageURL: URL(fileURLWithPath: p)).label((p as NSString).lastPathComponent) }
                prompt
            }
            for try await snap in stream {
                let j = snap.content.jsonString ?? "{}"
                if j != last { last = j; emit(["partial": j]) }
                u = usage(snap.usage)
            }
            emit(["done": true, "content": last, "usage": u])
        } catch { emit(explain(error)) }
    } else {
        let ses = wantPCC ? LanguageModelSession(model: pc, tools: [], transcript: tr)
                          : LanguageModelSession(model: fm, tools: [], transcript: tr)
        var last = "", u: [String: Int] = [:]
        do {
            let stream = ses.streamResponse(options: GenerationOptions(), contextOptions: ctx) {
                for p in imgs { Attachment(imageURL: URL(fileURLWithPath: p)).label((p as NSString).lastPathComponent) }
                prompt
            }
            for try await snap in stream {
                let c = snap.content
                if c.isEmpty { continue }
                if c.hasPrefix(last) { emit(["partial": String(c.dropFirst(last.count))]) }
                else { emit(["partial": c, "rewrite": true]) }
                last = c
                u = usage(snap.usage)
            }
            emit(["done": true, "content": last, "usage": u])
        } catch { emit(explain(error)) }
    }
}

func handle(_ r: [String: Any]) async {
    switch r["cmd"] as? String {
    case "status":
        var o: [String: Any] = ["fm": "\(fm.availability)", "window": fm.contextSize,
                                "pcc": "\(pc.availability)", "pcc_available": pc.isAvailable,
                                "quota": String("\(pc.quotaUsage.status)".prefix { $0 != "(" })]
        o["pcc_window"] = (try? await pc.contextSize) ?? -1
        o["schema_tokens"] = (try? await fm.tokenCount(for: schema(r["schema"] as? [String: Any]) ?? GenerationSchema(type: GeneratedContent.self, properties: []))) ?? -1
        emit(o)
    case "count":
        emit(["tok": (try? await fm.tokenCount(for: Instructions(r["text"] as? String ?? ""))) ?? -1])
    case "ask":
        await ask(r)
    default:
        emit(["error": "unknown cmd"])
    }
}

// stdin is line-delimited; exit when the harness closes the pipe
let rl = CommandLine.arguments
if rl.count > 1, rl[1] == "--handshake" { emit(["ok": true, "pid": ProcessInfo.processInfo.processIdentifier]); exit(0) }
while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let d = line.data(using: .utf8), let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        emit(["error": "bad json: \(line.prefix(60))"]); continue
    }
    await handle(r)
}
