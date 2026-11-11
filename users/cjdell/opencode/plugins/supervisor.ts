import { appendFileSync, statSync, writeFileSync } from "node:fs"
import { Plugin } from "@opencode/plugin"

// Supervisor — a copilot for the primary (Strata) agent, judged by LFM3.
//
// The box runs long-horizon agent sessions on Strata's Qwen3.8-Flash-Next
// (R9700). This plugin watches every session's thinking and intervenes in
// two failure classes:
//
//   1. ENDLESS THINKING LOOP — but ONLY on LARGE thinking steps. The loop
//      risk lives in steps that start to balloon (healthy reasoning runs
//      ~100-400 tokens; strata's degenerate episodes emit 1000+ token
//      chunks — see docs/strata-degeneration.md). Steps under
//      LARGE_STEP_CHARS are not supervised at all: cheap, and immune to
//      false positives on terse correct reasoning. Two tiers for big steps:
//      a. token collapse (the engine `!!!!`/`索索索` fp16 class): the
//         in-flight stream's char n-gram uniqueness collapses. Local,
//         interrupt immediately — this class burns the whole budget.
//      b. verbatim semantic loop: >= STEP_RUN consecutive similar COMPLETED
//         big steps (word-4gram Jaccard). Interrupt directly (deterministic
//         — three >1k-token near-identical re-derivations are never
//         healthy). The LFM3 judge NEVER sits in this path: it is good but
//         slow (~14 s at this lane's speed) and every second of judge time
//         is more wasted generation.
//   2. PREMATURE STOP. On session.idle with a real thinking run behind it:
//      - deterministic when unambiguous (agent ran tools but emitted no
//        text, or thought hard then said nothing),
//      - judge-gated when ambiguous (short-but-nonempty final text).
//      Nudge = a queued prompt demanding completion + a user-facing report.
//
// Every nudge is bounded (sliding windows per kind) so the supervisor can
// never loop with the model; everything logs with a [supervisor] prefix to
// the opencode server log (~/.local/share/opencode/log/opencode.log).
//
// Why a raw fetch for the judge instead of ctx.experimental.generate: the
// judge must stay invisible to session/token accounting (it would otherwise
// queue behind Strata on the same single-slot engine), and LFM3 emits a
// reasoning preamble before content (AGENTS.md "LFM3-1.7B"), which needs a
// budgeted, either-channel parse.
//
// Env overrides:
//   LFM3_ENDPOINT         pin a single judge URL (default: loopback, then the zen3 LAN URL)
//   SUPERVISOR_DISABLED=1 load and log, but never act

// LFM3 judge lanes: loopback on zen3 (where the RX 580 service runs), then
// zen3's LAN URL via nginx. zen3 serves Strata for the whole fleet, so it
// serves the supervisor's judge the same way: every LAN host gets the FULL
// behaviour, identical to zen3's. Off-LAN machines fail both lanes and
// degrade as before (deterministic gates keep working). We rotate on
// transport/HTTP failure and stay rotated; a parse failure means the lane
// answered, so it does not rotate.
const JUDGE_URLS =
  typeof process !== "undefined" && process.env?.LFM3_ENDPOINT
    ? [process.env.LFM3_ENDPOINT]
    : [
        "http://127.0.0.1:8086/v1/chat/completions",
        "http://192.168.49.50/lfm3/v1/chat/completions",
      ]
let judgeIdx = 0
let lastLane = ""
const DISABLED = typeof process !== "undefined" && process.env?.SUPERVISOR_DISABLED === "1"

// --- thresholds (measured 2026-11-11 against synthetic signatures) ---
// ~1000 tokens of reasoning at ~4 chars/token: the "starts to get large"
// line. Below this a step is NOT supervised (user-set policy: this is where
// the looping risk concentrates).
const LARGE_STEP_CHARS = 4000
// Immediate-interrupt gate for the ENGINE failure class only. Measured
// unique-8-gram ratios of a 1000-char tail: strata token collapse
// ('!'x3000, '索'x3000) ~0.001; legitimately repetitive reasoning (same
// sentence re-stated 0.039, markdown-table enumeration 0.049) sits 40x
// higher — so 0.01 fires on nothing but a degenerate stream.
const COLLAPSE_UNIQUE_RATIO = 0.01
const COLLAPSE_CHECK_EVERY = 600 // new chars between live collapse checks
const STEP_SIM = 0.6 // word-4gram Jaccard for "same thought" (verbatim-loop pairs >=0.69, progressing pairs <=0.06)
const STEP_RUN = 3 // consecutive similar LARGE-step pairs -> interrupt (deterministic)
const STEP_KEEP = 6 // completed steps remembered per session (ring, for digests)
const STEP_TEXT_KEEP = 1600 // digest tail kept per step
const FINAL_TOO_SHORT = 120 // idle-turn final text under this many chars may need a judge
const JUDGE_MAX_TOKENS = 1200 // measured: 900 was still cut mid-thinking; 1200 finished (stop) in ~14 s with valid JSON
const IDLE_JUDGE_TIMEOUT_MS = 90_000 // at idle nothing is burning; the judge runs ONLY here (the loop interrupt never waits on it)
const ACT_COOLDOWN_MS = 60_000 // per (session, kind)
const HOUR = 3_600_000
const BUDGET_LOOP = 4 // interrupts per session per hour
const BUDGET_STOP = 3 // idle re-kicks per session per hour

// The opencode service's stdout is /dev/null, so console.log from a plugin is
// lost. Interventions must be auditable ("why did the supervisor interrupt
// my run?"), so log to a dedicated append-only file instead.
const LOG_FILE = `${(typeof process !== "undefined" && process.env?.HOME) || "/home/cjdell"}/.local/share/opencode/supervisor.log`
const log = (...a: unknown[]) => {
  try {
    appendFileSync(
      LOG_FILE,
      `${new Date().toISOString()} [supervisor] ${a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" ")}\n`,
    )
  } catch {
    // logging must never break supervision
  }
}

// ---------------- pure detectors ----------------

const norm = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^\p{L}\p{N} ]/gu, " ")
    .replace(/\s+/g, " ")
    .trim()

const wordShingles = (s: string, k = 4): Set<string> => {
  const w = norm(s).split(" ").filter(Boolean)
  const out = new Set<string>()
  for (let i = 0; i + k <= w.length; i++) out.add(w.slice(i, i + k).join(" "))
  if (out.size === 0 && w.length > 1) for (const x of w) out.add(x) // fallback: bag of words
  return out
}

const jaccard = (a: Set<string>, b: Set<string>) => {
  if (a.size === 0 || b.size === 0) return 0
  let inter = 0
  for (const x of a) if (b.has(x)) inter++
  return inter / (a.size + b.size - inter)
}

// Fraction of distinct char n-grams in the tail (repetition collapse meter).
const uniqueRatio = (s: string, n = 8, tailChars = 1000) => {
  const t = s.length > tailChars ? s.slice(-tailChars) : s
  if (t.length < n * 4) return 1
  const seen = new Set<string>()
  let total = 0
  for (let i = 0; i + n <= t.length; i++, total++) seen.add(t.slice(i, i + n))
  return seen.size / total
}

const tail = (s: string, n: number) => (s.length > n ? "…" + s.slice(-n) : s)

// ---------------- judge ----------------

type Verdict = { loop: boolean; unfinished: boolean; nudge: string } | null

const parseVerdict = (text: string): Verdict => {
  const m = text.match(/\{[\s\S]*\}/)
  if (!m) return null
  try {
    const v = JSON.parse(m[0])
    return {
      loop: v.loop === true,
      unfinished: v.unfinished === true,
      nudge: typeof v.nudge === "string" ? v.nudge.slice(0, 200) : "",
    }
  } catch {
    return null
  }
}

const judge = async (user: string, timeoutMs: number): Promise<Verdict> => {
  for (let attempt = 0; attempt < JUDGE_URLS.length; attempt++) {
    const url = JUDGE_URLS[judgeIdx]
    try {
      const response = await fetch(url, {
        method: "POST",
        signal: AbortSignal.timeout(timeoutMs),
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          model: "LFM3-1.7B",
          messages: [
            {
              role: "system",
              content:
                "You watch an autonomous coding agent. Reply with one JSON object and nothing else.",
            },
            { role: "user", content: user },
          ],
          max_tokens: JUDGE_MAX_TOKENS,
          temperature: 0,
          stream: false,
        }),
      })
      if (!response.ok) throw new Error(`status ${response.status}`)
      const body: any = await response.json()
      const msg = body?.choices?.[0]?.message ?? {}
      lastLane = url
      // LFM3 fills reasoning_content BEFORE content; accept either, content first.
      return (
        parseVerdict(String(msg.content ?? "")) ?? parseVerdict(String(msg.reasoning_content ?? ""))
      )
    } catch {
      judgeIdx = (judgeIdx + 1) % JUDGE_URLS.length
    }
  }
  return null
}

// ---------------- plugin state ----------------

type Step = { chars: number; text: string }

type SessionState = {
  steps: Step[] // completed reasoning steps this run (small ones kept for digest only)
  simRun: number // consecutive similar LARGE-step pairs
  live: { key: string; text: string; checked: number } // in-flight reasoning stream
  finalText: string // last assistant text content
  toolSeen: boolean // assistant content of this run contained tool parts
  task: string // last real user prompt (for the judge digest)
  acts: { loop: number[]; stop: number[] }
  lastAct: Record<string, number>
  acting: boolean
  consumed: boolean // this run already got its loop interrupt
}

export default Plugin.define({
  id: "supervisor",
  async setup(ctx: any) {
    const sessions = new Map<string, SessionState>()
    const sessionLocks = new Map<string, number>() // lock-file path -> last act ts (in-process cache)
    const blank = (): SessionState => ({
      steps: [],
      simRun: 0,
      live: { key: "", text: "", checked: 0 },
      finalText: "",
      toolSeen: false,
      task: "",
      acts: { loop: [], stop: [] },
      lastAct: {},
      acting: false,
      consumed: false,
    })
    const state = (id: string) => {
      let s = sessions.get(id)
      if (!s) {
        if (sessions.size > 400) sessions.clear() // coarse memory bound
        sessions.set(id, (s = blank()))
      }
      return s
    }
    const freshRun = (s: SessionState) => {
      s.steps = []
      s.simRun = 0
      s.live = { key: "", text: "", checked: 0 }
      s.finalText = ""
      s.toolSeen = false
      s.consumed = false
    }

    const spend = (s: SessionState, kind: "loop" | "stop", sessionID: string) => {
      const now = Date.now()
      // Cross-instance guard: the service runs one plugin instance per
      // location (workspace) and every instance receives every event, so a
      // lock file - not just this instance's window - enforces the cooldown.
      try {
        const lock = `${LOG_FILE.slice(0, LOG_FILE.lastIndexOf("/"))}/supervisor-${kind}.lock`
        const recent = (sessionLocks.get(lock) ?? 0) || statSync(lock).mtimeMs
        if (now - recent < ACT_COOLDOWN_MS) return false
        writeFileSync(lock, `${new Date().toISOString()} ${sessionID}`)
        sessionLocks.set(lock, now)
      } catch {
        // lock file unavailable (first act / FS hiccup) -> proceed
      }
      const limit = kind === "loop" ? BUDGET_LOOP : BUDGET_STOP
      s.acts[kind] = s.acts[kind].filter((t) => now - t < HOUR)
      if (s.acts[kind].length >= limit) return false
      if (now - (s.lastAct[kind] ?? 0) < ACT_COOLDOWN_MS) return false
      s.acts[kind].push(now)
      s.lastAct[kind] = now
      return true
    }

    const act = async (
      sessionID: string,
      kind: "loop" | "stop",
      why: string,
      nudge: string,
      interruptFirst: boolean,
    ) => {
      const s = state(sessionID)
      if (DISABLED || s.acting) return
      s.acting = true
      try {
        if (!spend(s, kind, sessionID)) {
          log(`budget/cooldown — no nudge (${kind})`, sessionID, `(${why})`)
          return
        }
        const text = `[supervisor] ${nudge}`
        log(`NUDGE ${kind} session=${sessionID} (${why}) -> ${JSON.stringify(nudge)}`)
        if (interruptFirst) {
          try {
            await ctx.session.interrupt({ sessionID, resume: false })
          } catch (e: any) {
            log("interrupt failed:", e?.message ?? e)
          }
        }
        await ctx.session.prompt({ sessionID, text, delivery: interruptFirst ? "steer" : "queue" })
      } catch (e: any) {
        log("act failed:", e?.message ?? e)
      } finally {
        s.acting = false
      }
    }

    const digest = (s: SessionState, kind: "loop" | "stop") => {
      const steps = s.steps
        .slice(-3)
        .map((st, i) => `${i + 1}: ${tail(st.text, 260)}`)
        .join("\n")
      return [
        `TASK: ${tail(s.task, 400)}`,
        kind === "loop" ? `BIG THINKING STEPS (tails):\n${steps}` : "",
        kind === "loop" ? `similar consecutive pairs: ${s.simRun}` : "",
        `FINAL MESSAGE TO USER: ${s.finalText ? tail(s.finalText, 400) : "(none)"}`,
        kind === "loop"
          ? `Is the agent stuck re-deriving the same thing with no progress? If stuck: loop=true, nudge=one imperative instruction naming a concrete next action.`
          : `The agent ended its turn. Did it FAIL to deliver a usable report/answer to the user? If unfinished: unfinished=true, nudge=one imperative instruction to continue and end with a results summary. If it looks done (including "cannot proceed" explained to the user): unfinished=false.`,
        `Answer exactly: {"loop":true|false,"unfinished":true|false,"nudge":"<=25 words"}`,
      ]
        .filter(Boolean)
        .join("\n\n")
    }

    // ---------------- subscriptions ----------------

    const controller = new AbortController()

    void (async () => {
      for await (const event of ctx.event.subscribe({
        signal: controller.signal,
        types: [
          "session.reasoning.started",
          "session.reasoning.delta",
          "session.reasoning.ended",
          "session.idle",
        ],
      })) {
        try {
          const d = event.data ?? {}
          const id = d.sessionID
          if (!id) continue

          if (event.type === "session.reasoning.started") {
            const s = state(id)
            const key = `${d.assistantMessageID}:${d.ordinal}`
            if (s.live.key !== key) s.live = { key, text: "", checked: 0 }
          } else if (event.type === "session.reasoning.delta") {
            const s = state(id)
            const key = `${d.assistantMessageID}:${d.ordinal}`
            if (s.live.key !== key) s.live = { key, text: "", checked: 0 }
            s.live.text = (s.live.text + (d.delta ?? "")).slice(-6000)
            // Tier 1a (LARGE steps only): live collapse of the ENGINE class.
            if (
              !s.consumed &&
              s.live.text.length >= LARGE_STEP_CHARS &&
              s.live.text.length - s.live.checked > COLLAPSE_CHECK_EVERY
            ) {
              s.live.checked = s.live.text.length
              if (uniqueRatio(s.live.text) < COLLAPSE_UNIQUE_RATIO) {
                s.consumed = true
                await act(
                  id,
                  "loop",
                  "token collapse in a large live thinking step",
                  "Your thinking collapsed into repetition. Discard it, restate the single next concrete action, and take it (call a tool or write the final summary).",
                  true,
                )
              }
            }
          } else if (event.type === "session.reasoning.ended") {
            const s = state(id)
            s.live = { key: "", text: "", checked: 0 }
            const text = String(d.text ?? "")
            const big = text.length >= LARGE_STEP_CHARS
            const prev = s.steps.at(-1)
            // Tier 1b entry condition: BOTH steps of the pair must be large.
            const sim =
              big && prev && prev.chars >= LARGE_STEP_CHARS
                ? jaccard(wordShingles(prev.text), wordShingles(text))
                : 0
            s.simRun = sim >= STEP_SIM ? s.simRun + 1 : 0
            s.steps.push({ chars: text.length, text: text.slice(0, STEP_TEXT_KEEP) })
            if (s.steps.length > STEP_KEEP) s.steps.shift()
            if (s.simRun >= STEP_RUN && !s.consumed) {
              // Deterministic interrupt with a generic nudge. The LFM3 judge
              // CAN produce a much better task-specific nudge (verified
              // 2026-11-11) but needs ~14 s at this lane's speed — unaffordable
              // while the engine is burning tokens, so it never sits in this
              // path. It serves the idle stop-gate only.
              s.consumed = true
              await act(
                id,
                "loop",
                `${s.simRun} consecutive similar large thinking steps`,
                "You are re-deriving the same conclusion. Stop thinking, execute the next tool call, or report the blocker to the user.",
                true,
              )
            }
          } else if (event.type === "session.idle") {
            const s = state(id)
            if (s.consumed) {
              freshRun(s) // our own interrupt ended the run; the steer prompt continues it
              continue
            }
            // Read the finished turn from session context (the durable record;
            // content-updated events are not subscribable in v2.2.7).
            let finalText = "",
              toolSeen = false,
              reasoningChars = 0,
              finish = ""
            try {
              const msgs: any[] = await ctx.session.context({ sessionID: id })
              for (let i = msgs.length - 1; i >= 0; i--) {
                const m = msgs[i]
                const role = m?.type ?? m?.role
                if (role === "user") break // run had no assistant turn
                if (role === "assistant") {
                  const parts = Array.isArray(m.content) ? m.content : []
                  finalText = parts
                    .filter((p: any) => p?.type === "text")
                    .map((p: any) => p.text ?? "")
                    .join("\n")
                    .trim()
                  toolSeen = parts.some((p: any) => p?.type === "tool")
                  reasoningChars = parts
                    .filter((p: any) => p?.type === "reasoning")
                    .reduce((n: number, p: any) => n + (p.text?.length ?? 0), 0)
                  finish = String(m.rawFinish ?? m.finish ?? "")
                  break
                }
              }
            } catch (e: any) {
              log("context fetch failed:", e?.message ?? e)
            }
            s.finalText = finalText
            s.toolSeen = toolSeen
            const finalChars = finalText.length
            const silentWork = finalChars === 0 && toolSeen
            const thoughtThenSilence = finalChars === 0 && reasoningChars >= LARGE_STEP_CHARS
            const truncated = /length/i.test(finish) && finalChars < 4 * FINAL_TOO_SHORT
            if (silentWork || thoughtThenSilence || truncated) {
              // Unambiguous: work happened but no usable report, or the turn
              // was cut off mid-stream. Deterministic, no judge needed.
              await act(
                id,
                "stop",
                silentWork
                  ? "silent stop (tools ran, no final text)"
                  : truncated
                    ? `turn hit the token limit (rawFinish=${finish}) with a short final message`
                    : "large thinking step then stopped without a final message",
                "The previous turn ended without a usable user-facing result. Continue the task to completion and end with a concise report of results and anything left undone.",
                false,
              )
            } else if (finalChars > 0 && finalChars < FINAL_TOO_SHORT) {
              // Ambiguous (a terse "done" may be a complete answer) -> judge-gated.
              const v = await judge(digest(s, "stop"), IDLE_JUDGE_TIMEOUT_MS)
              if (v?.unfinished) {
                await act(
                  id,
                  "stop",
                  `final text < ${FINAL_TOO_SHORT} chars, judge agrees unfinished`,
                  v.nudge ||
                    "End the task with a concise report of results and anything left undone.",
                  false,
                )
              }
            }
            freshRun(s)
          }
        } catch (e: any) {
          log("event handler error:", e?.message ?? e)
        }
      }
    })()

    // Capture the real user task for digests; a user prompt is a run boundary.
    const promptHook = await ctx.session.hook("prompt", (event: any) => {
      const text = String(event?.prompt?.text ?? "")
      if (!text) return
      const s = state(event.sessionID)
      if (!text.startsWith("[supervisor]")) {
        s.task = text
        freshRun(s)
      }
    })

    // Startup self-test: prove the judge lane answers, without blocking load.
    void (async () => {
      const t0 = Date.now()
      const v = await judge(`Reply exactly: {"loop":false,"unfinished":false,"nudge":"ping"}`, 30_000)
      log(
        v
          ? `judge online via ${lastLane} (${Date.now() - t0} ms)`
          : `judge UNREACHABLE on ${JUDGE_URLS.join(" | ")} — loop detection unaffected (deterministic), ambiguous stop checks skipped`,
      )
      if (DISABLED) log("SUPERVISOR_DISABLED=1 — observing only")
    })()

    return () => {
      controller.abort()
      void promptHook?.dispose?.()
    }
  },
})
