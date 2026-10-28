# nya ♡

A kawaii hacker harness for Apple's **FoundationModels** — on-device FM and
Private Cloud Compute behind one prompt, with six file/shell tools and a real
token budget. **732 lines of Swift, no Xcode, no dependencies.**

```
     ╭──────────────────────────────────────────╮
     │   /\_/\    n y a   ♡   hacker harness    │
     │  ( o.o )   Apple FoundationModels        │
     │   > ^ <    + Private Cloud Compute       │
     ╰──────────────────────────────────────────╯
```

## Build

Needs macOS 27 (the FoundationModels SDK lives there) and the Command Line
Tools — Xcode is *not* required.

```sh
./build.sh    # swiftc -target arm64-apple-macosx27.0, writes ./nya
./nya         # from whatever directory you want it to work in
```

Start it where your code is: relative paths resolve to its cwd.

## Use it

Type plainly and it looks before it speaks:

```
♡ nya ⌒> rename parseDate to parseTime in Sources/ingest.swift and fix the callers
  ♡ read Sources/ingest.swift · 4 lines
  ♡ grep parseDate · 3 hits
  ⚠ edit Sources/ingest.swift
  yes no always →
```

Reads, greps and globs run silently. **`write`, `edit` and `bash` stop and
ask**: `y` once, `n` refuses, `a` approves that tool for the session. When
stdin isn't a terminal nobody is there to say yes, so the gate **fails
closed** — use `/yolo` deliberately if you want unattended runs. Ctrl-C
interrupts a turn without killing the session.

## Commands

| | |
|---|---|
| `/fm` `/pcc` `/m` | swap brain — local FM is free and fast, PCC reasons bigger |
| `/think l\|m\|d` | PCC reasoning depth (tokens rise with it) |
| `/img <path>` | attach a screenshot or photo to your next message |
| `/gate` `/yolo` | confirm risky tools, or let everything run |
| `/chat` | toggle answering small talk without loading the tool schemas |
| `/budget 0.5` `/compress` `/c` | compaction threshold, or fold history now |
| `/status` | availability, quota, and where the fixed tokens go |
| `/tools` | the tool surface |
| `/save <n>` `/load <n>` `/ls` | sessions in `~/.nya/sessions/*.json` |
| `/clear` | new transcript, same directory |

End a line with `\` for multiline input. `/h` lists everything.

## Tokens

The HUD is measured, not estimated:

```
╰─ fm ♡ 1245/8192 15% ↑3 tok · gate on · 1 turns
```

Everything costs what it says via `usage.input/output/reasoningTokenCount`.
On-device context is 8,192 tokens and about 1,089 of them are overhead before
you type a word (248 instructions + 841 tool schemas), so nya guards it
hard: tool output is capped and de-duplicated before it enters history,
history auto-compacts at 60% of the window (`/budget`), a mid-turn overflow
summarises and retries once, a runaway loop is cut at 24 tool calls, and
small talk skips the tool schema entirely (`/chat`).

## Private Cloud Compute

`/pcc` compiles and routes correctly, but Apple will refuse a plain binary
with `ModelManagerError 1046`: the process must be signed with a real
identity **and** a provisioning profile carrying the
`com.apple.developer.private-cloud-compute` entitlement. Ad-hoc signing is not
enough — the entitlement survives signing but the process is then SIGKILLed.

`./app.sh` builds `Nya.app` for that case:

```sh
./app.sh "Apple Development: you@example.com (TEAMID)" ~/Downloads/nya.provision
out/Nya.app/Contents/MacOS/nya        # exec it, don't `open` it — a TUI needs your tty
```

If PCC fails at any point mid-request, nya says so, drops to `/fm` and
retries the same turn rather than dying.

## Why so few lines

`LanguageModelSession` runs the agentic tool loop itself — streaming, tool
dispatch, and re-asking until done are the framework's job, so there is no
hand-rolled loop, no JSON-schema builder, and no regex parser of model output.
The other trick is that tools are declared without `@Generable`/`@Guide`:
the macro plugin only ships inside Xcode, so `Tool` is implemented with
`Arguments == GeneratedContent` and a hand-built `GenerationSchema`, and each
tool is one line of spec:

```swift
Fn("edit|Replace old with new in a file.|path:s:file,old:s:exact text,new:s:replacement,all:s?:true")
```

```
Sources/nya/Brain.swift  323   routing, streaming, budget, compaction, persistence
Sources/nya/Pal.swift     90   palette, serialised printer, raw keypress, safe runner
Sources/nya/Tools.swift  213   six tools, approval gate, output capping
Sources/nya/main.swift   106   banner, REPL, slash commands
```

`grep` and `glob` spawn `/usr/bin/grep` and `/usr/bin/find` through argv
arrays — no shell string is ever assembled from model output. `bash` is the
only tool that reaches a shell, and it is gated.

## Tests

`demo/gate.exp` drives the harness on a real pty and asserts the gate blocks
a write, then that `/yolo` releases it:

```sh
expect demo/gate.exp "$PWD"    # OK [gate blocked the write] / OK [/yolo let it through]
```

## Acknowledgements

Architecture questions were settled against
[1rgs/nanocode](https://github.com/1rgs/nanocode) and
[Sentdex/minion](https://github.com/Sentdex/minion); both hand-roll the loop,
which is where most of their length goes.
