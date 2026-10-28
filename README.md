# nya ♡

A kawaii hacker harness for Apple's **FoundationModels** — on-device FM and
Private Cloud Compute behind one prompt, six file/shell tools, a measured token
budget, and a y/n/a gate on anything that touches disk. Two editions live here:

```
     ╭──────────────────────────────────────────╮
     │   /\_/\    n y a   ♡   hacker harness    │
     │  ( o.o )   Apple FoundationModels        │
     │   > ^ <    + python brain · swift shim   │
     ╰──────────────────────────────────────────╯
```

| | |
|---|---|
| `python/` | **the harness**: loop, tools, gate, budget, persistence in Python; `shim.swift` (155 lines) is the only Swift, because FoundationModels cannot be reached any other way |
| `swift/` | the original edition: whole harness in 743 lines of Swift, where `LanguageModelSession` runs the tool loop for you |

## Why a shim at all

FoundationModels is Swift-only: no `Headers/`, zero `_OBJC_CLASS_` symbols, so
PyObjC has nothing to bridge and no pip package can exist. The split keeps only
the irreducible part in Swift — the shim owns streaming, schema compilation and
token counts, and speaks JSON-lines over stdin/stdout. The agent loop, the tools
and every policy decision are Python.

## Build

Needs macOS 27 (that's where the FoundationModels SDK lives) plus the Command
Line Tools — Xcode is *not* required.

```sh
cd python && ./build.sh && python3 nya.py     # shim + harness
```

Start it where your code is: relative paths resolve to its cwd. The Swift
edition is `cd swift && ./build.sh && ./nya`.

## Use it

Type plainly and it looks before it speaks:

```
♡ nya ⌒> rename parseDate to parseTime in Sources/ingest.swift and fix the callers
  ♡ read Sources/ingest.swift · 4 lines
  ♡ grep parseDate · 3 hits
  ⚠ edit Sources/ingest.swift
  yes no always → y
```

Reads, greps and globs run silently. **`write`, `edit` and `bash` stop and ask**:
`y` once, `n` refuses, `a` approves that tool for the session. The chosen letter
stays on screen, so an approval is never mistaken for an auto-run. When stdin
isn't a terminal nobody is there to say yes, so the gate **fails closed** — pass
`/yolo` deliberately for unattended runs. Ctrl-C interrupts a turn without
killing the session.

## Commands

| | |
|---|---|
| `/fm` `/pcc` `/m` | swap brain — local FM is free and fast, PCC reasons bigger |
| `/think l\|m\|d` | PCC reasoning depth (tokens rise with it) |
| `/img <path>` | attach a screenshot or photo to your next message |
| `/gate` `/yolo` | confirm risky tools, or let everything run |
| `/chat` | answer small talk without loading the tool schema |
| `/budget 0.5` `/compress` `/c` | compaction threshold, or fold history now |
| `/status` | availability, quota, and where the fixed tokens go |
| `/tools` | the tool surface |
| `/save <n>` `/load <n>` `/ls` | sessions in `~/.nya/sessions/*.json` |
| `/clear` | new transcript, same directory |

End a line with `\` for multiline input. `/h` lists everything.

## Tokens

The HUD is measured, not estimated:

```
╰─ fm ♡ 389/8192 4% ↑39 tok · gate on · 3 msgs
```

Everything costs what it says via `usage.input/output/reasoningTokenCount`, and
the python edition is the cheaper one because it declares **one** flat step
object instead of six tool definitions:

```
flat step schema        288 tok     (python/nya.py — say|tool|path|content|old|new|…)
six native tool defs    841 tok     (swift/Sources/nya — plus 248 of instructions)
```

Same task, same model, measured end to end — `read demo/list.txt and tell me the
third line`:

```
python  389 tok · 3 msgs      swift  1,132 tok · 1 turn
```

On-device context is 8,192 tokens, so nya guards it hard: tool output is capped
and de-duplicated before it enters history, history auto-compacts at 60% of the
window (`/budget`), a mid-turn overflow summarises and retries once, and small
talk skips the tool schema entirely (`/chat`). Loop caps: 12 tool calls per turn
in python, 24 in swift.

## Not letting it lie to you

The on-device model is small and will happily answer about a file it never
opened. Observed, then defended against:

- **look-before-say** — if your message names a file (`path-ish` or a real
  extension) and the first step answers with no tool call, that answer is
  buffered, not streamed, and the model gets one hard nudge to actually `read`
  or `grep`. If it still answers blind, the reply is flagged
  `⌒ I did not open that file — treat this as unverified`.
- **no self-echo** — an answer about an attached image never greps the repo for
  it; the prompt forbids it because a fabrication in the transcript reinforces
  itself.
- **repeat breakers** — the same failing call twice in a turn appends *"you have
  failed this exact call 2 times, stop retrying"*; an identical call that already
  succeeded is never re-run, its earlier result is handed back with *"answer the
  user now"*. Both counters are per-turn, so a legitimate re-check next turn
  isn't blocked.
- **honest tool errors** — missing path, empty `read` path, empty `grep`
  pattern, a glob pattern containing slashes: each returns a specific
  `no such file or directory` / `failed: …` string that matches the failure
  keywords above. Silent `(no output)` is never returned for a search.

## Private Cloud Compute

`/pcc` compiles and routes correctly, but Apple refuses a plain binary with
`ModelManagerError 1046`: the process must be signed with a real identity **and**
a provisioning profile carrying the `com.apple.developer.private-cloud-compute`
entitlement. Ad-hoc signing is not enough — the entitlement survives signing,
then the process is SIGKILLed.

`swift/app.sh` builds `Nya.app` for that case:

```sh
cd swift && ./app.sh "Apple Development: you@example.com (TEAMID)" ~/Downloads/nya.provision
out/Nya.app/Contents/MacOS/nya        # exec it, don't `open` it — a TUI needs your tty
```

If PCC fails mid-request, nya says so, drops to `/fm` and retries the same turn
rather than dying. Both editions read the same entitlement, so the shim is the
only thing that has to be signed.

## Layout

```
python/nya.py        668   loop, 6 tools, gate, budget, compaction, sessions, TUI
python/shim.swift    155   FoundationModels bridge: ask/status/count over JSON-lines
swift/Sources/nya/Brain.swift   324  routing, streaming, budget, compaction, persistence
swift/Sources/nya/Pal.swift      90  palette, serialised printer, raw keypress, safe runner
swift/Sources/nya/Tools.swift   223  six tools, approval gate, output capping
swift/Sources/nya/main.swift    106  banner, REPL, slash commands
```

`grep` and `glob` spawn `/usr/bin/grep` and `/usr/bin/find` through argv arrays —
no shell string is ever assembled from model output. `bash` is the only tool that
reaches a shell, and it is gated.

## Tests

Both editions are driven on a real pty (piped stdin can't exercise a raw-mode
gate) and assert the gate blocks a write, then that `/yolo` releases it:

```sh
expect python/demo/gate.exp "$PWD"          # OK [gate blocked the write] / OK [/yolo let it through]
expect swift/demo/gate.exp "$PWD/swift"     # same, for the swift binary
```

## Acknowledgements

Architecture questions were settled against
[1rgs/nanocode](https://github.com/1rgs/nanocode) and
[Sentdex/minion](https://github.com/Sentdex/minion); both hand-roll the loop,
which is where most of their length goes — the python edition hand-rolls it too,
and pays for it in nudge logic rather than in Swift.
