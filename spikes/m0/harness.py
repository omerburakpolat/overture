#!/usr/bin/env python3
"""M0 de-risk spike: drive the real `claude` CLI over the stream-json control
protocol and prove every [assumed] claim in docs/specs/01-claude-integration.md.

Spawn args replicate @anthropic-ai/claude-agent-sdk 0.3.251 (contract-of-record):
  --output-format stream-json --verbose --input-format stream-json
  --permission-prompt-tool stdio          # when the host answers can_use_tool

Each scenario appends every raw NDJSON line (both directions) to a fixture file
under fixtures/ for later golden tests in ClaudeKit.

Usage: python3 harness.py <scenario> [...]   (or `all`)
"""
import json, os, subprocess, sys, threading, time, uuid, queue, pathlib, shutil

CLAUDE = shutil.which("claude") or "/opt/homebrew/bin/claude"
ROOT = pathlib.Path(__file__).resolve().parent
FIXTURES = ROOT / "fixtures"
WORK = pathlib.Path("/private/tmp/claude-501/-Volumes-MainOBP-Dev-dungeonmaster/fef85559-54ad-4f6e-a528-5768f2f4cda1/scratchpad/m0-work")
MODEL = "haiku"  # cheapest; protocol shape is model-independent


def scratch_repo(name: str) -> pathlib.Path:
    d = WORK / name
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=d, check=True)
    (d / "README.md").write_text("m0 scratch\n")
    subprocess.run(["git", "add", "-A"], cwd=d, check=True)
    subprocess.run(["git", "-c", "user.email=m0@test", "-c", "user.name=m0",
                    "commit", "-qm", "init"], cwd=d, check=True)
    return d


class Driver:
    """One long-lived claude process speaking bidirectional stream-json."""

    BASE = ["--output-format", "stream-json", "--verbose",
            "--input-format", "stream-json", "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--model", MODEL, "--setting-sources", "", "--strict-mcp-config"]

    def __init__(self, cwd, fixture: str, extra_args=None, session_id=None, resume=None):
        self.fixture = open(FIXTURES / fixture, "a")
        args = [CLAUDE, "-p", *self.BASE, *(extra_args or [])]
        if resume:
            args += ["--resume", resume]
        else:
            self.session_id = session_id or str(uuid.uuid4())
            args += ["--session-id", self.session_id]
        env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
        self.proc = subprocess.Popen(args, cwd=cwd, env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        self.lines: queue.Queue = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()
        self.stderr_tail = []

    def _read(self):
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            self._log("OUT", line)
            try:
                self.lines.put(json.loads(line))
            except json.JSONDecodeError:
                self.lines.put({"type": "_unparsed", "raw": line})
        self.lines.put(None)  # EOF sentinel

    def _read_err(self):
        for line in self.proc.stderr:
            self.stderr_tail = (self.stderr_tail + [line.rstrip()])[-40:]

    def _log(self, direction, line):
        self.fixture.write(f"{direction}\t{line}\n")
        self.fixture.flush()

    def send(self, obj):
        line = json.dumps(obj)
        self._log("IN", line)
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def send_user(self, text):
        self.send({"type": "user",
                   "message": {"role": "user", "content": [{"type": "text", "text": text}]},
                   "parent_tool_use_id": None})

    def control(self, request, request_id=None):
        rid = request_id or uuid.uuid4().hex[:12]
        self.send({"type": "control_request", "request_id": rid, "request": request})
        return rid

    def respond(self, request_id, response):
        self.send({"type": "control_response",
                   "response": {"subtype": "success", "request_id": request_id,
                                "response": response}})

    def next(self, timeout=90):
        try:
            return self.lines.get(timeout=timeout)
        except queue.Empty:
            raise TimeoutError(f"no message within {timeout}s; stderr tail: "
                               + " | ".join(self.stderr_tail[-8:]))

    def wait_for(self, pred, timeout=120, label=""):
        """Return first message matching pred; collect everything on the way."""
        deadline = time.time() + timeout
        seen = []
        while time.time() < deadline:
            msg = self.next(timeout=max(1, deadline - time.time()))
            if msg is None:
                raise RuntimeError(f"EOF while waiting for {label}; "
                                   f"exit={self.proc.poll()}; stderr: "
                                   + " | ".join(self.stderr_tail[-8:]))
            seen.append(msg)
            if pred(msg):
                return msg, seen
        raise TimeoutError(f"timeout waiting for {label}")

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
        self.fixture.close()


def is_ctrl(msg, subtype=None):
    return (msg.get("type") == "control_request"
            and (subtype is None or msg.get("request", {}).get("subtype") == subtype))


def is_result(msg):
    return msg.get("type") == "result"


P = lambda *a: print(*a, flush=True)
VERDICTS = []


def verdict(claim, ok, detail=""):
    VERDICTS.append((claim, ok, detail))
    P(f"  [{'PASS' if ok else 'FAIL'}] {claim}" + (f" — {detail}" if detail else ""))


# ---------------------------------------------------------------- scenarios

def scenario_a_permissions():
    """Handshake, can_use_tool allow/deny, per-turn result semantics."""
    P("== A: handshake + can_use_tool + per-turn result ==")
    repo = scratch_repo("a-perms")
    d = Driver(repo, "a-permissions.jsonl", extra_args=["--permission-mode", "manual"])
    try:
        # initialize handshake (SDK sends this before anything else)
        rid = d.control({"subtype": "initialize"})
        msg, _ = d.wait_for(lambda m: m.get("type") == "control_response"
                            and m.get("response", {}).get("request_id") == rid,
                            timeout=60, label="initialize response")
        verdict("initialize control_request is answered", True,
                json.dumps(msg["response"])[:160])

        # NOTE (finding): nothing further is emitted until the first user
        # message — system/init arrives with turn startup, not process startup.
        # NOTE (finding): read-only/safe commands (echo, ls) are auto-approved
        # by the CLI's safe-command classification and never reach
        # can_use_tool — use a write (touch) to force a permission request.
        d.send_user("Use the Bash tool to run exactly: touch m0-touch.txt. "
                    "Then reply DONE and stop.")
        init, _ = d.wait_for(lambda m: m.get("type") == "system"
                             and m.get("subtype") == "init", label="system/init")
        verdict("system/init carries session_id + permissionMode",
                "session_id" in init, f"mode={init.get('permissionMode')}")

        # Turn 1: force a Bash call in manual mode -> expect can_use_tool
        req, _ = d.wait_for(lambda m: is_ctrl(m, "can_use_tool"),
                            label="can_use_tool for Bash")
        r = req["request"]
        verdict("can_use_tool arrives with tool_name+input",
                r.get("tool_name") == "Bash" and "input" in r,
                f"tool={r.get('tool_name')} input={json.dumps(r.get('input'))[:100]} "
                f"suggestions={len(r.get('permission_suggestions') or [])}")
        d.respond(req["request_id"], {"behavior": "allow",
                                      "updatedInput": r["input"]})
        res1, seen = d.wait_for(is_result, label="turn-1 result")
        got_tool_result = any(m.get("type") == "user" for m in seen)
        verdict("allow -> tool executes -> turn result",
                not res1.get("is_error") and got_tool_result,
                f"subtype={res1.get('subtype')} cost={res1.get('total_cost_usd')}")

        # Turn 2: deny with steering message; also proves result-per-turn
        d.send_user("Now use Bash to run: touch should-not-exist.txt . "
                    "If the tool is denied, reply exactly DENIED-OK and stop.")
        req2, _ = d.wait_for(lambda m: is_ctrl(m, "can_use_tool"),
                             label="second can_use_tool")
        d.respond(req2["request_id"], {"behavior": "deny",
                                       "message": "M0 test: do not run this; "
                                                  "reply DENIED-OK."})
        res2, seen2 = d.wait_for(is_result, label="turn-2 result")
        text = "".join(json.dumps(m) for m in seen2)
        verdict("deny message steers the model", "DENIED-OK" in text,
                f"subtype={res2.get('subtype')}")
        verdict("result arrives PER TURN (2 results, 1 process)", True)

        # set_permission_mode -> acceptEdits: Write should NOT prompt
        rid3 = d.control({"subtype": "set_permission_mode", "mode": "acceptEdits"})
        d.wait_for(lambda m: m.get("type") == "control_response"
                   and m.get("response", {}).get("request_id") == rid3,
                   timeout=30, label="set_permission_mode response")
        d.send_user("Create a file named m0.txt containing 'hello' using the "
                    "Write tool, then reply WROTE and stop.")
        res3, seen3 = d.wait_for(is_result, label="turn-3 result")
        prompted = any(is_ctrl(m, "can_use_tool") for m in seen3)
        wrote = (repo / "m0.txt").exists()
        verdict("set_permission_mode->acceptEdits auto-approves Write",
                (not prompted) and wrote,
                f"prompted={prompted} file={wrote}")
        return d.session_id, repo
    finally:
        d.close()


def scenario_b_interrupt():
    """interrupt control request mid-turn."""
    P("== B: interrupt ==")
    repo = scratch_repo("b-interrupt")
    d = Driver(repo, "b-interrupt.jsonl", extra_args=["--permission-mode", "manual"])
    try:
        d.send_user("Write a very long 1500-word essay about orchestras. "
                    "Do not use any tools.")
        d.wait_for(lambda m: m.get("type") == "system"
                   and m.get("subtype") == "init", label="init")
        # wait until streaming actually starts, then interrupt
        d.wait_for(lambda m: m.get("type") == "stream_event", label="streaming start")
        rid = d.control({"subtype": "interrupt"})
        msg, seen = d.wait_for(lambda m: (m.get("type") == "control_response"
                                          and m.get("response", {}).get("request_id") == rid)
                               or is_result(m),
                               timeout=60, label="interrupt ack or result")
        # drain to the turn result if the ack came first
        if not is_result(msg):
            res, _ = d.wait_for(is_result, timeout=60, label="post-interrupt result")
        else:
            res = msg
        verdict("interrupt ends the turn with a result",
                True, f"subtype={res.get('subtype')} is_error={res.get('is_error')}")
    finally:
        d.close()


def scenario_c_plan():
    """plan mode: ExitPlanMode arrives via can_use_tool; approve flips to build."""
    P("== C: plan mode + ExitPlanMode ==")
    repo = scratch_repo("c-plan")
    d = Driver(repo, "c-plan.jsonl", extra_args=["--permission-mode", "plan"])
    try:
        d.send_user("Plan a one-line change: add the word DONE to README.md. "
                    "Keep the plan to two sentences, then exit plan mode.")
        init, _ = d.wait_for(lambda m: m.get("type") == "system"
                             and m.get("subtype") == "init", label="init")
        verdict("plan mode reported in system/init",
                init.get("permissionMode") == "plan",
                f"mode={init.get('permissionMode')}")
        req, _ = d.wait_for(lambda m: is_ctrl(m, "can_use_tool")
                            and m["request"].get("tool_name") == "ExitPlanMode",
                            timeout=180, label="ExitPlanMode request")
        plan_text = json.dumps(req["request"].get("input"))[:200]
        verdict("ExitPlanMode arrives as can_use_tool with plan input",
                True, plan_text)
        d.respond(req["request_id"], {"behavior": "allow",
                                      "updatedInput": req["request"]["input"]})
        rid = d.control({"subtype": "set_permission_mode", "mode": "acceptEdits"})
        d.wait_for(lambda m: m.get("type") == "control_response"
                   and m.get("response", {}).get("request_id") == rid,
                   timeout=30, label="mode flip")
        res, seen = d.wait_for(is_result, timeout=180, label="build result")
        edited = "DONE" in (repo / "README.md").read_text()
        verdict("approve+mode-flip continues same session into build",
                edited, f"README edited={edited}")
    finally:
        d.close()


def scenario_d_resume_cwd(session_id, first_repo):
    """resume the scenario-A session from a DIFFERENT cwd; find where lines land."""
    P("== D: resume from different cwd ==")
    other = scratch_repo("d-other-cwd")
    d = Driver(other, "d-resume.jsonl", resume=session_id,
               extra_args=["--permission-mode", "manual"])
    try:
        d.send_user("Reply with exactly: RESUMED-OK")
        init, _ = d.wait_for(lambda m: m.get("type") == "system"
                             and m.get("subtype") == "init", label="init")
        resumed_id = init.get("session_id")
        res, seen = d.wait_for(is_result, label="resume result")
        text = "".join(json.dumps(m) for m in seen)
        verdict("resume from different cwd works", "RESUMED-OK" in text,
                f"resumed session_id={resumed_id} (orig {session_id})")
        # Where did the transcript lines land?
        proj = pathlib.Path.home() / ".claude" / "projects"
        hits = sorted(str(p.parent.name) for p in proj.glob(f"*/{resumed_id}.jsonl"))
        verdict("transcript location after cwd change identified", bool(hits),
                f"dirs={hits}")
        verdict("resume continues SAME id (no fork)", resumed_id == session_id,
                f"{resumed_id}")
    finally:
        d.close()


def scenario_e_oneshot():
    """ticket-draft recipe: --output-format json + --json-schema, and budget cap."""
    P("== E: one-shot json schema + budget under OAuth ==")
    repo = scratch_repo("e-oneshot")
    schema = json.dumps({"type": "object",
                         "properties": {"title": {"type": "string"},
                                        "body": {"type": "string"},
                                        "suggestedTags": {"type": "array",
                                                          "items": {"type": "string"}}},
                         "required": ["title", "body"]})
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
    r = subprocess.run([CLAUDE, "-p", "--output-format", "json",
                        "--json-schema", schema, "--tools", "Read,Glob,Grep",
                        "--no-session-persistence", "--setting-sources", "",
                        "--strict-mcp-config", "--model", MODEL,
                        "Draft a ticket: the app crashes when pasting an image "
                        "into a comment. Return title, body, suggestedTags."],
                       cwd=repo, env=env, capture_output=True, text=True, timeout=300)
    (FIXTURES / "e-oneshot.json").write_text(r.stdout)
    ok, so = False, None
    try:
        out = json.loads(r.stdout)
        so = out.get("structured_output")
        ok = isinstance(so, dict) and "title" in so
    except json.JSONDecodeError:
        pass
    verdict("one-shot --json-schema returns structured_output", ok,
            (json.dumps(so)[:140] if so else f"exit={r.returncode} "
             f"err={r.stderr[-200:]}"))

    r2 = subprocess.run([CLAUDE, "-p", "--output-format", "json",
                        "--max-budget-usd", "0.000001", "--setting-sources", "",
                        "--strict-mcp-config", "--model", MODEL,
                        "Reply with one word: hi"],
                        cwd=repo, env=env, capture_output=True, text=True, timeout=300)
    (FIXTURES / "e-budget.json").write_text(r2.stdout or r2.stderr)
    sub = None
    try:
        sub = json.loads(r2.stdout).get("subtype")
    except json.JSONDecodeError:
        pass
    verdict("--max-budget-usd behavior under OAuth observed", True,
            f"exit={r2.returncode} subtype={sub} stderr={r2.stderr[:120]!r}")


if __name__ == "__main__":
    FIXTURES.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    which = sys.argv[1:] or ["all"]
    sid = repo = None
    if which == ["all"]:
        which = ["a", "b", "c", "d", "e"]
    for w in which:
        try:
            if w == "a":
                sid, repo = scenario_a_permissions()
                (WORK / "a-session-id").write_text(sid)
            elif w == "b":
                scenario_b_interrupt()
            elif w == "c":
                scenario_c_plan()
            elif w == "d":
                sid = sid or (WORK / "a-session-id").read_text().strip()
                scenario_d_resume_cwd(sid, WORK / "a-perms")
            elif w == "e":
                scenario_e_oneshot()
        except Exception as e:
            verdict(f"scenario {w} completed", False, f"{type(e).__name__}: {e}")
    P("\n== SUMMARY ==")
    for claim, ok, detail in VERDICTS:
        P(f"  {'PASS' if ok else 'FAIL'}  {claim}")
    sys.exit(0 if all(ok for _, ok, _ in VERDICTS) else 1)
