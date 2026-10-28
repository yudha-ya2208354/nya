#!/usr/bin/env python3
"""nya ♡ — kawaii hacker harness for Apple FoundationModels, python edition.

FoundationModels is a Swift-only framework: no headers, no Objective-C classes, so no
Python binding can exist. Everything except the model call lives here; shim.swift is a
JSON-lines bridge that owns only streaming, schemas and token counts.
"""
import glob as pyglob
import json, os, re, shlex, subprocess, sys, signal

ROOT = os.getcwd()
HOME = os.path.expanduser("~")
OFF, BOLD, ASH = "\x1b[0m", "\x1b[1m", "\x1b[38;5;245m"
ROSE, BUBBLE, MINT, LILAC, GOLD, SKY, CORAL = 218, 205, 122, 183, 229, 159, 203


def t(n, s):
    return f"\x1b[38;5;{n}m{s}{OFF}" if isinstance(n, int) else f"{n}{s}{OFF}"


def say(s=""):
    sys.stdout.write(s + "\n")
    sys.stdout.flush()


def warn(s):
    say("  " + t(CORAL, "! " + s))


def ohai(s):
    say("  " + t(MINT, s))


INT = {"hit": False}


def on_int(*_):
    INT["hit"] = True


class Shim:
    """One long-lived child process; requests and replies are line-delimited JSON."""

    def __init__(self):
        self.exe = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shim")
        if not os.path.exists(self.exe):
            sys.exit("no ./shim next to nya.py — run ./build.sh first")
        self.p = None
        self.start()

    def start(self):
        self.p = subprocess.Popen([self.exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, bufsize=1)

    def _recv(self):
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("shim exited — rebuild it with ./build.sh")
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return {"error": "unparsable shim line: " + line[:80]}

    def simple(self, req):
        """status and count answer in a single line."""
        if self.p.poll() is not None:
            self.start()
        self.p.stdin.write(json.dumps(req) + "\n")
        self.p.stdin.flush()
        o = self._recv()
        if "error" in o:
            raise RuntimeError(str(o["error"])[:200])
        return o

    def ask(self, req, on_partial=None):
        """Stream one request. Returns (content, usage, err, interrupted)."""
        if self.p.poll() is not None:
            self.start()
        self.p.stdin.write(json.dumps(req) + "\n")
        self.p.stdin.flush()
        content, usage, err, cut = "", {}, None, False
        while True:
            try:
                o = self._recv()
            except RuntimeError:
                raise
            if "usage" in o:
                usage = o["usage"]
            if "partial" in o:
                if INT["hit"]:
                    cut = True
                elif on_partial:
                    on_partial(o)
                continue
            if "done" in o:
                content = o.get("content", "")
                break
            if "error" in o:
                err = o
                break
        return content, usage, err, cut


TOOL_NAMES = ["read", "write", "edit", "grep", "glob", "bash"]

STEP = {"name": "step", "desc": "answer the user, or ask for exactly one tool", "props": [
    {"n": "say", "d": "text shown to the user", "t": "s", "o": True},
    {"n": "tool", "d": "tool to run", "t": "e", "o": True, "c": TOOL_NAMES},
    {"n": "path", "d": "file, or directory for grep/glob", "t": "s", "o": True},
    {"n": "content", "d": "whole new file text", "t": "s", "o": True},
    {"n": "old", "d": "exact text to find", "t": "s", "o": True},
    {"n": "new", "d": "replacement text", "t": "s", "o": True},
    {"n": "all", "d": "true replaces every match", "t": "b", "o": True},
    {"n": "pattern", "d": "regex, or filename glob", "t": "s", "o": True},
    {"n": "fi", "d": "filename filter like *.swift", "t": "s", "o": True},
    {"n": "offset", "d": "first line", "t": "i", "o": True},
    {"n": "limit", "d": "lines to read", "t": "i", "o": True},
    {"n": "command", "d": "shell command", "t": "s", "o": True},
]}

RISKY = {"write", "edit", "bash"}
approved = set()
repeat = {}


def abso(p):
    if p.startswith("~"):
        return HOME + p[1:]
    return p if p.startswith("/") else os.path.join(ROOT, p)


def rel(p):
    return p[len(ROOT) + 1:] if p.startswith(ROOT + "/") else p


def clip(s, n):
    s = s.replace("\n", " ")
    return s if len(s) <= n else s[:n - 1] + "…"


def capped(s, n=2500):
    """Trim tool output before it enters history — the biggest token saving there is."""
    out, total, run, last = [], 0, 0, None
    for ln in s.split("\n"):
        if ln == last:
            run += 1
            if run > 3:
                continue
        else:
            run, last = 0, ln
        total += len(ln) + 1
        if total > n:
            out.append(f"[…truncated at {n} chars — use offset/limit to page]")
            break
        out.append(ln)
    return "\n".join(out) if out else "(empty)"


def run(argv, timeout=30):
    """argv arrays only — no shell string is ever assembled from model output."""
    try:
        r = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return f"[killed: over {timeout}s]"
    except OSError as e:
        return f"failed to run {argv[0]}: {e}"
    out = (r.stdout + r.stderr).rstrip()
    return out if out else "(no output)"


def preview_of(a):
    for k in ("pattern", "path", "command"):
        if a.get(k):
            return clip(str(a[k]), 60)
    return ""


def tool_read(a):
    if not a.get("path"):
        return "failed: read needs a path"
    p = abso(str(a.get("path", "")))
    try:
        ls = open(p, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        return f"no such file or unreadable text: {rel(p)}"
    frm = max(1, int(a.get("offset") or 1))
    to = min(len(ls), frm + max(1, int(a.get("limit") or 80)) - 1)
    body = "\n".join(f"{i:>4}\t{ls[i - 1]}" for i in range(frm, max(frm, to) + 1))
    if to < len(ls):
        body += f"\n… {len(ls) - to} more lines (offset:{to + 1})"
    return body


def tool_write(a):
    p = abso(str(a.get("path", "")))
    body = str(a.get("content", ""))
    os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
    open(p, "w", encoding="utf-8").write(body)
    return f"wrote {rel(p)} ({len(body)} chars)"


def tool_edit(a):
    p = abso(str(a.get("path", "")))
    old, new = str(a.get("old", "")), str(a.get("new", ""))
    try:
        txt = open(p, encoding="utf-8").read()
    except OSError:
        return f"no such file: {rel(p)}"
    if not old:
        return "failed: old must not be empty"
    n = txt.count(old)
    if n == 0:
        if new and new in txt:
            return f"already applied — {rel(p)} already contains the new text. Nothing to do; move on."
        return f"not found: {clip(old, 80)}. Re-read the file and copy the exact text including whitespace."
    if n > 1 and not a.get("all"):
        return f"ambiguous: {clip(old, 60)} matches {n} times. Add more context, or set all:true."
    open(p, "w", encoding="utf-8").write(txt.replace(old, new))
    return f"edited {rel(p)} — {n if a.get('all') else 1} site(s)"


def tool_grep(a):
    pat = str(a.get("pattern") or "")
    if not pat:
        return "failed: grep needs a pattern"
    dir_ = abso(str(a.get("path") or "."))
    if not os.path.exists(dir_):
        return f"no such file or directory: {rel(dir_)}"
    argv = ["/usr/bin/grep", "-rnI", "-E", pat]
    if a.get("fi"):
        argv += ["--include", str(a["fi"])]
    argv.append(dir_)
    raw = run(argv, 20)
    if raw == "(no output)":
        return f"no matches for {pat}"
    hits = raw.split("\n")
    body = "\n".join(rel(h) if h else h for h in hits[:60])
    return body + ("" if len(hits) <= 60 else f"\n… {len(hits) - 60} more matches")


def tool_glob(a):
    pat = str(a.get("pattern") or "*")
    if "/" in pat:
        # a pattern with slashes is a path, not a -name — python's own glob, never a shell
        fs = [rel(f) for f in pyglob.glob(abso(pat), recursive=True) if os.path.isfile(f)][:200]
        return "\n".join(fs) if fs else "no matches for " + pat
    pats = shlex.split(pat)
    dir_ = abso(str(a.get("path") or "."))
    if not os.path.isdir(dir_):
        return f"no such file or directory: {rel(dir_)}"
    argv = ["/usr/bin/find", dir_]
    argv += ["-name", pats[0] if pats else "*", "-type", "f", "-not", "-path", "*/.git/*"]
    raw = run(argv, 20)
    fs = [rel(f) for f in (raw.split("\n") if raw != "(no output)" else [])][:200]
    try:
        fs.sort(key=lambda f: -os.path.getmtime(abso(f)))
    except OSError:
        pass
    return "\n".join(fs) if fs else "no matches for " + (pats[0] if pats else "*")


def tool_bash(a):
    cmd = str(a.get("command", ""))
    if not cmd:
        return "failed: empty command"
    try:
        r = subprocess.run(cmd, shell=True, cwd=ROOT, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return "[killed: over 60s]"
    out = (r.stdout + r.stderr).rstrip() or "(no output)"
    return out if r.returncode == 0 else out + f"\n[exit {r.returncode}]"


TOOLS = {"read": tool_read, "write": tool_write, "edit": tool_edit,
         "grep": tool_grep, "glob": tool_glob, "bash": tool_bash}

SYS = f"""nya: terse terminal coding agent. cwd {ROOT}.
Call tools ONLY for what the user asked for. Greetings, opinions, feelings and questions about you are answered in plain text with no tool call.
Never create, edit, or log to a file the user did not name. Never invent a task, and never report work you did not do.
Before saying anything about code, look with read/grep — never guess file contents. edit > write. Relative paths ok.
Never grep or read files to find the content of an attached image — it is already in front of you.
Answer in under 120 words, no preamble, no markdown headings. Code blocks only when asked to.
End with one line on what changed, or what you still need — unless you changed nothing, then just answer."""

SOFT = """nya: warm tiny terminal sidekick. 1-3 short lines, no preamble, no markdown, one kaomoji is welcome.
You have no tools here. Never invent file contents and never claim you did work. If the message really needs files or commands, say it got routed to chat by mistake and ask for the path."""

CHATTY = set("""hi hii hello hey heya hiya yo sup howdy hallo heyo how are you doing today ok okay k good
great fine well bad nm hbu wbu thanks thank ty yw np sorry welcome lol lmao rofl wow wowza cool nice cute
amazing sad angry tired i im am me my mine ur your is it this that so very really just too not no yes yeah
yep nope and but or please pls who what can do sleep feel know think guess love hate fuck fucking shit wtf
stupid dumb useless suck yay oops bye cya gtg hmm huh oh ah aha meh um erm anyway god man dude bro""".split())


def is_chatty(s):
    ws = [w for w in re.split(r"[^a-z0-9]+", s.lower()) if w]
    return 0 < len(ws) <= 6 and all(w in CHATTY for w in ws)


# a message that names something file-shaped: the model must look before it speaks
PATHISH = re.compile(r"[\w.-]*/[\w./-]|\w+\.(?:py|txt|md|sh|exp|swift|json|ya?ml|toml|js|ts|tsx|css|html|c|h|go|rs|rb|java|ini|env)\b")


def partial_say(js):
    """Pull the answer text out of a half-generated JSON object so it can stream."""
    try:
        return str(json.loads(js).get("say") or "")
    except json.JSONDecodeError:
        m = re.search(r'"say"\s*:\s*"((?:[^"\\]|\\.)*)', js)
        if not m:
            return ""
        try:
            return json.loads('"' + m.group(1) + '"')
        except json.JSONDecodeError:
            return m.group(1)


def key(q):
    """One keypress. No tty means nobody is there to say yes, so refuse."""
    sys.stdout.write(q)
    sys.stdout.flush()
    if not sys.stdin.isatty():
        say(t(CORAL, "n") + " " + t(ASH, "(stdin is not a terminal — /yolo to run unattended)"))
        return "n"
    saved = subprocess.run(["stty", "-g"], capture_output=True, text=True).stdout.strip()
    subprocess.run(["stty", "raw", "-echo"], stderr=subprocess.DEVNULL)
    try:
        ch = sys.stdin.read(1) or "\x03"
    finally:
        if saved:
            subprocess.run(["stty", saved], stderr=subprocess.DEVNULL)
    say(ch)
    return ch


def allow(tool, preview, gate):
    if not gate or tool not in RISKY or tool in approved:
        return True
    q = ("\n  " + t(GOLD, f"⚠ {tool}") + " " + t(ASH, preview) + "\n  "
         + t(MINT, "y") + "es " + t(CORAL, "n") + "o " + t(SKY, "a") + "lways → ")
    c = key(q)
    if c in "aA":
        approved.add(tool)
        ohai(f"auto-approved {tool} for this session")
        return True
    return c in "yY\n "


class Brain:
    def __init__(self):
        self.sh = Shim()
        self.info = self.sh.simple({"cmd": "status", "schema": STEP})
        self.window = self.info.get("window", 8192) or 8192
        self.fix = max(0, self.info.get("schema_tokens", 0))
        self.msgs, self.imgs, self.spoke = [], [], False
        self.pcc, self.think, self.gate, self.chat = False, "", True, True
        self.used = self.gen = self.reas = 0
        self.budget, self.cap = 0.60, 12

    def hud(self):
        pct = int(self.used / self.window * 100) if self.window else 0
        c = CORAL if pct > 85 else GOLD if pct > 60 else MINT
        model = ("pcc/" + self.think) if (self.pcc and self.think) else ("pcc" if self.pcc else "fm")
        return ("  " + t(ASH, "╰─") + " " + t(LILAC, model) + " " + t(ASH, f"♡ {self.used}/{self.window}")
                + t(c, f" {pct}%") + " "
                + t(ASH, f"↑{self.gen} tok · {'gate on' if self.gate else 'YOLO'} · {len(self.msgs)} msgs"))

    def render(self, text):
        say("  " + t(BUBBLE, " ᵔᵕᵔ ") + " " + text)

    def step(self, prompt, schema=True, stream=True):
        req = {"cmd": "ask", "instructions": SYS if schema else SOFT, "messages": self.msgs,
               "prompt": prompt, "pcc": self.pcc, "think": self.think,
               "images": self.imgs if schema else [], "schema": STEP if schema else None}
        if not schema:
            self.imgs = []
        printed = [""]

        def on_partial(o):
            if not stream:
                return
            body = o["partial"]
            if schema:
                # schema partials are the whole object generated so far, not a delta
                txt = partial_say(body)
            else:
                # text partials are deltas unless the shim had to rewrite the answer
                txt = body if o.get("rewrite") else printed[0] + body
            if not txt.startswith(printed[0]) and printed[0]:
                printed[0] = txt
                return
            fresh = txt[len(printed[0]):]
            if fresh and not printed[0]:
                sys.stdout.write("  " + t(BUBBLE, " ᵔᵕᵔ ") + " ")
            sys.stdout.write(fresh)
            sys.stdout.flush()
            printed[0] = txt

        out = self.sh.ask(req, on_partial)
        self.spoke = bool(printed[0])
        if printed[0]:
            say("")
        return out

    def turn(self, text, retried=False):
        repeat.clear()
        force = bool(PATHISH.search(text))
        nudged, looked, seen = False, False, {}
        for i in range(self.cap):
            content, usage, err, cut = self.step("continue" if i else text,
                                                 stream=not (force and i == 0))
            if usage:
                self.used, self.gen, self.reas = usage.get("in", 0), usage.get("out", 0), usage.get("reas", 0)
            if cut:
                warn("interrupted")
                return
            if err:
                if err.get("overflow") and not retried:
                    warn("context full — compacting, then retrying")
                    self.compact("overflow")
                    return self.turn(text, True)
                if self.pcc and err.get("pcc_down") and not retried:
                    warn(f"pcc unavailable ({err.get('dom', '?')} #{err.get('code', '?')}) — retrying on-device")
                    self.pcc = False
                    return self.turn(text, True)
                warn(str(err.get("error", "model failed"))[:200])
                return
            try:
                got = json.loads(content)
            except json.JSONDecodeError:
                got = {"say": content}
            name = str(got.get("tool") or "").strip()
            if name not in TOOLS:
                ans = str(got.get("say") or "")
                if force and not nudged and not looked:
                    nudged = True
                    say("  " + t(ASH, "⌒ named a file but did not look — asking it to read first"))
                    self.msgs.append({"r": "nya", "t": ans})
                    self.msgs.append({"r": "tool", "t": "You answered about that file without reading it, so "
                                                        "your answer is invented. Call read or grep on the path "
                                                        "now, then answer from what you actually saw. If you "
                                                        "cannot open it, say so instead of guessing."})
                    continue
                if force and not looked:
                    say("  " + t(GOLD, "⌒ I did not open that file — treat this as unverified"))
                    ans += " [self-reported: did not read the file]"
                if not self.spoke:
                    self.render(ans)
                self.msgs.append({"r": "nya", "t": ans})
                if self.used > self.budget * self.window:
                    self.compact("budget")
                return
            args = {k: v for k, v in got.items() if k not in ("say", "tool") and v not in (None, "")}
            prev = preview_of(args)
            said = str(got.get("say") or "")
            ck = f"{name}|{prev}"
            if ck in seen:
                if said:
                    return
                self.msgs.append({"r": "tool", "t": f"[you already ran {name} {prev}] {seen[ck][:240]}\n"
                                                    "That result has not changed. Answer the user now."})
                continue
            self.msgs.append({"r": "nya", "t": (said + " " if said else "") + f"[calling {name} {prev}]"})
            if not allow(name, prev, self.gate):
                seen[ck] = "the user declined this"
                say("  " + t(CORAL, "✗") + " " + t(CORAL, BOLD + name + OFF) + " " + t(ROSE, prev)
                    + " " + t(ASH, "· declined by user"))
                self.msgs.append({"r": "tool", "t": "The user declined this action. Do not retry it; "
                                                     "ask what they would prefer instead."})
                continue
            out = capped(str(TOOLS[name](args)))
            seen[ck] = out
            looked = True
            bad = any(w in out for w in ("not found", "no such file", "failed", "ambiguous", "declined",
                                         "no matches", "already applied"))
            k = f"{name}|{prev}"
            repeat[k] = repeat.get(k, 0) + 1 if bad else 0
            if repeat[k] >= 2:
                out += (f"\nYou have failed this exact call {repeat[k]} times. "
                        "Stop retrying it; change approach or ask the user.")
            first = out.split("\n")[0]
            say("  " + t(LILAC, "♡") + " " + t(LILAC, BOLD + name + OFF) + " " + t(ROSE, prev) + " "
                + t(ASH, "· " + (clip(first, 44) if "\n" not in out else f"{len(out.splitlines())} lines")))
            self.msgs.append({"r": "tool", "t": out})
        warn(f"stopped after {self.cap} tool calls — /compress or narrow the ask")

    def whisper(self, prompt):
        c, _, err, _ = self.sh.ask({"cmd": "ask", "instructions": "", "messages": [], "prompt": prompt})
        if err:
            warn("summary failed: " + str(err.get("error"))[:120])
        return c

    def compact(self, why):
        """Fold the older messages into one note; if there is nothing to fold, deflate tool output."""
        if len(self.msgs) < 5:
            self.msgs = [{"r": m["r"], "t": (m["t"][:200] + "…") if m["r"] == "tool" and len(m["t"]) > 200 else m["t"]}
                         for m in self.msgs]
            ohai(f"nothing to fold ({why}) — trimmed tool output instead")
            return
        head, tail = self.msgs[:-2], self.msgs[-2:]
        dump = capped("\n".join(f"{m['r']}: {m['t'][:400]}" for m in head), 9000)
        note = self.whisper("Compress this coding-agent transcript into notes I can act on. Keep every file "
                            "path, decision and reason, unresolved task, exact number. 120 words max.\n\n" + dump)
        self.msgs = [{"r": "nya", "t": f"[earlier, {len(head)} messages compressed] {note}"}] + tail
        _, u, _, _ = self.sh.ask({"cmd": "ask", "instructions": SYS, "messages": self.msgs,
                                  "prompt": ".", "schema": STEP})
        self.used = u.get("in", self.used)
        ohai(f"notes saved, window now {self.used}/{self.window}")

    def route(self, to_pcc):
        if to_pcc and not self.info.get("pcc_available"):
            warn(f"PCC unavailable: {self.info.get('pcc')}")
            return
        self.pcc = to_pcc
        ohai(f"{'pcc' if to_pcc else 'fm'} ready · window {self.window} · "
             f"{'reasoning on' if to_pcc else 'on-device'}")


def help_():
    rows = [
        ("/m  /fm  /pcc", "switch brain — fm is local & free, pcc is bigger + reasons"),
        ("/think l|m|d", "PCC reasoning level (tokens rise with depth)"),
        ("/gate  /yolo", "confirm write/edit/bash, or run everything"),
        ("/chat", "small talk answered without the tool schema"),
        ("/img <path>", "attach an image to your next message"),
        ("/compress  /c", "fold old messages into notes"),
        ("/budget <0-1>", "auto-compaction threshold"),
        ("/clear", "fresh transcript, keep this chat's files"),
        ("/save <n> /load <n> /ls", "session JSON in ~/.nya/sessions"),
        ("/tools", "list the tool surface"),
        ("/status", "model availability, quota, schema cost"),
    ]
    for c, d in rows:
        say("  " + t(MINT, c.ljust(24)) + t(ASH, d))
    say(t(ASH, "  end a line with \\ for multiline · Ctrl-C interrupts a turn"))


def slash(b, s):
    """Returns True when the session should end."""
    parts = s.split(maxsplit=1)
    c, a = parts[0], (parts[1].strip() if len(parts) > 1 else "")
    if c in ("/q", "/quit", "/exit", "/bye"):
        return True
    if c in ("/h", "/help", "/?"):
        help_()
    elif c == "/fm":
        b.route(False)
    elif c in ("/pcc", "/cloud"):
        b.route(True)
    elif c in ("/m", "/model"):
        b.route(not b.pcc)
    elif c == "/think":
        b.think = {"l": "light", "m": "moderate", "d": "deep"}.get(a, a if a in ("light", "moderate", "deep") else "")
        ohai(f"reasoning: {b.think or 'off'} — pcc only")
    elif c == "/gate":
        b.gate = True
        approved.clear()
        ohai("confirming write/edit/bash again")
    elif c == "/yolo":
        b.gate = False
        warn(f"YOLO — the model can write and run anything in {ROOT}")
    elif c == "/chat":
        b.chat = not b.chat
        ohai(f"small talk bypasses tools: {'on' if b.chat else 'off'}")
    elif c == "/budget":
        try:
            d = float(a)
            if 0.05 < d <= 0.95:
                b.budget = d
        except ValueError:
            pass
        ohai(f"compact at {int(b.budget * 100)}% of window")
    elif c in ("/compress", "/c"):
        b.compact("manual")
    elif c == "/clear":
        b.msgs, b.used = [], 0
        ohai("transcript cleared")
    elif c == "/tools":
        for p in STEP["props"][1:]:
            say("  " + t(LILAC, p["n"].ljust(9)) + t(ASH, p["d"]))
    elif c == "/status":
        i = b.info
        say("  " + t(LILAC, "fm  ") + t(ASH, str(i.get("fm"))))
        say("  " + t(BUBBLE, "pcc ") + t(ASH, f"{i.get('pcc')} · quota {i.get('quota')}"))
        say("  " + t(MINT, "now ") + t(ASH, f"{'pcc' if b.pcc else 'fm'} · window {b.window} · used {b.used} "
                                          f"({b.gen} generated, {b.reas} reasoning)"))
        say("  " + t(ASH, f"flat step schema {b.fix} tok — one object, not {len(TOOL_NAMES)} tool definitions"))
    elif c == "/img":
        p = abso(a)
        if not a or not os.path.exists(p):
            warn("usage: /img path/to.png")
        else:
            b.imgs.append(p)
            ohai(f"attached {rel(p)} ({len(b.imgs)} pending)")
    elif c == "/save":
        d = f"{HOME}/.nya/sessions"
        os.makedirs(d, exist_ok=True)
        n = re.sub(r"[^A-Za-z0-9._-]", "_", a or "last")
        json.dump(b.msgs, open(f"{d}/{n}.json", "w"))
        ohai(f"saved {d}/{n}.json ({len(b.msgs)} messages)")
    elif c == "/load":
        n = re.sub(r"[^A-Za-z0-9._-]", "_", a or "last")
        f = f"{HOME}/.nya/sessions/{n}.json"
        if not os.path.exists(f):
            warn(f"no session {f}")
        else:
            b.msgs = json.load(open(f))
            ohai(f"loaded {len(b.msgs)} messages from {n}.json")
    elif c == "/ls":
        d = f"{HOME}/.nya/sessions"
        fs = sorted(f for f in os.listdir(d) if f.endswith(".json")) if os.path.isdir(d) else []
        say("\n".join("  " + t(MINT, f) for f in fs) if fs else "  " + t(ASH, "no saved sessions"))
    else:
        warn(f"unknown {c} — /h")
    return False


BANNER = r"""     ╭──────────────────────────────────────────╮
     │   /\_/\    n y a   ♡   hacker harness    │
     │  ( o.o )   Apple FoundationModels        │
     │   > ^ <    + python edition, swift shim  │
     ╰──────────────────────────────────────────╯"""


def main():
    signal.signal(signal.SIGINT, on_int)
    say(t(ROSE, BANNER))
    say("  " + t(ASH, "on-device FM for free speed · PCC for big reasoning · 6 tools, loop driven from python"))
    say("  " + t(ASH, "/h for commands · Ctrl-C interrupts a turn · everything stays on this machine unless you /pcc"))
    b = Brain()
    say(b.hud())
    while True:
        INT["hit"] = False
        try:
            raw = input(t(ROSE, "♡ nya ") + t(ASH, "⌒> "))
        except EOFError:
            say(t(MINT, "  ╰─(^_^)/  bye — transcript not saved. /save <name> next time"))
            return
        line = raw.strip()
        if not line:
            continue
        if line.startswith("/"):
            if slash(b, line):
                say(t(MINT, "  ╰─(^_^)/  bye — transcript not saved. /save <name> next time"))
                return
            say(b.hud())
            continue
        while line.endswith("\\"):
            line = line[:-1].rstrip() + " " + input(t(ASH, "  … "))
        if b.chat and not b.imgs and is_chatty(line):
            say("  " + t(ASH, "⌒ small talk · no tool schema"))
            c, u, err, cut = b.step(line, schema=False)
            if err:
                warn(str(err.get("error", "model failed"))[:160])
            elif cut:
                warn("interrupted")
            else:
                b.gen, b.reas = u.get("out", 0), u.get("reas", 0)
                b.msgs += [{"r": "you", "t": line}, {"r": "nya", "t": c}]
            say(b.hud())
            continue
        b.msgs.append({"r": "you", "t": line})
        b.turn(line)
        say(b.hud())


if __name__ == "__main__":
    main()
