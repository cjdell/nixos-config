import { Plugin } from "@opencode/plugin"

// Auto-detect context windows for self-hosted OpenAI-compatible servers.
//
// OpenCode only knows a model's context limit from models.dev or an explicit
// `limit` in opencode.json; custom models fall back to a 200K default even when
// the server advertises more (llama.cpp-style servers report their real window
// as `meta.n_ctx` on /v1/models, which OpenCode ignores). This plugin probes
// each targeted provider's `/models` endpoint, reads `meta.n_ctx`, and overrides
// `limit.context` with it. It re-probes on a timer, so restarting the server
// with a different n_ctx is picked up automatically without config edits.
//
// Options (via the object form in opencode.json `plugins`):
//   providers:   provider IDs to probe (default: ["strata"])
//   pollSeconds: re-probe interval in seconds (default: 60)

type ModelsResponse = {
  data?: Array<{ id?: string; meta?: { n_ctx?: number } }>
}

export default Plugin.define({
  id: "auto-context",
  async setup(ctx) {
    const providerIDs: string[] = Array.isArray(ctx.options.providers)
      ? (ctx.options.providers as unknown[]).map(String)
      : ["strata"]
    const pollMs = Math.max(5, Number(ctx.options.pollSeconds ?? 60)) * 1000

    // providerID -> modelID -> context tokens. Mutated in place and read
    // synchronously by the model transform below.
    const limits = new Map<string, Map<string, number>>()
    // providerID -> trimmed baseURL, captured synchronously from the provider
    // registry during the transform (ctx.provider.list() omits providers that
    // have no integration, so the transform editor is the reliable source).
    const baseUrls = new Map<string, string>()

    const probe = async (): Promise<boolean> => {
      let changed = false
      for (const providerID of providerIDs) {
        const baseURL = baseUrls.get(providerID)
        if (!baseURL) continue
        try {
          const response = await fetch(`${baseURL}/models`, { signal: AbortSignal.timeout(5000) })
          if (!response.ok) continue
          const body = (await response.json()) as ModelsResponse
          const models = new Map<string, number>()
          for (const entry of body.data ?? []) {
            const nCtx = entry?.meta?.n_ctx
            if (typeof entry?.id === "string" && typeof nCtx === "number" && nCtx > 0) {
              models.set(entry.id, Math.floor(nCtx))
            }
          }
          if (models.size === 0) continue
          const previous = limits.get(providerID)
          const same =
            previous !== undefined &&
            previous.size === models.size &&
            [...models].every(([id, n]) => previous.get(id) === n)
          if (!same) {
            limits.set(providerID, models)
            changed = true
          }
        } catch {
          // Server unreachable right now; keep the last known limits and retry next poll.
        }
      }
      return changed
    }

    await ctx.model.transform((editor) => {
      for (const providerID of providerIDs) {
        const record = editor.provider.get(providerID)
        const baseURL: string | undefined = record?.provider.settings?.baseURL
        if (baseURL) baseUrls.set(providerID, baseURL.replace(/\/+$/, ""))
      }
      for (const [providerID, models] of limits) {
        for (const model of editor.list(providerID)) {
          const context = models.get(model.id)
          if (context === undefined) continue
          editor.update(providerID, model.id, (draft) => {
            if (draft.limit.context !== context) draft.limit.context = context
          })
        }
      }
    })

    // Force one registry rebuild so the transform captures the provider base
    // URLs before the first probe; later rebuilds (including reloads) re-run it.
    await ctx.model.list()

    const apply = async () => {
      if (await probe()) await ctx.model.reload()
    }

    // The first probe can fail while the plugin runtime is still activating,
    // so retry quickly (bounded) until at least one provider reports limits.
    let retries = 0
    let fast: ReturnType<typeof setInterval> | undefined
    const applyOrRetry = () => {
      void apply()
        .catch(() => {})
        .finally(() => {
          if (limits.size === 0 && ++retries < 10 && fast) return
          if (fast !== undefined) {
            clearInterval(fast)
            fast = undefined
          }
        })
    }
    fast = setInterval(applyOrRetry, 2000)
    applyOrRetry()

    const timer = setInterval(() => void apply().catch(() => {}), pollMs)
    return () => {
      clearInterval(timer)
      if (fast !== undefined) clearInterval(fast)
    }
  },
})
