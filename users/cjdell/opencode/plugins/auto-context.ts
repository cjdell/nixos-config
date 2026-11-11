import { Model, Plugin, Provider } from "@opencode/plugin"

// Auto-detect models and context windows for self-hosted OpenAI-compatible servers.
//
// Adds the provider itself plus one OpenCode model per entry the server's
// `/models` endpoint reports, using the server-advertised ID, `meta.n_ctx` as
// the context limit, and `architecture.{input,output}_modalities` as
// capabilities. Adding or removing models on the server, or changing n_ctx, is
// picked up on the next poll with no opencode.json edits — no model or provider
// entry is needed in the config at all.
//
// It also maintains one stable alias ID that always points at the server's
// currently-loaded model, so sessions and references keep working when the
// llama.cpp alias changes, and makes that alias the catalog default unless
// `setDefault: false` is passed.
//
// Options (via the object form in opencode.json `plugins`; all optional):
//   endpoint:    server root, default "https://strata.ai.chrisdell.info/v1"
//                (or the STRATA_ENDPOINT environment variable)
//   providerID:  catalog provider ID, default "strata"
//   stableID:    alias ID kept pointing at the loaded model, default
//                "qwen3.8-flash-next-ud-iq4-xs"; set "" to disable
//   setDefault:  make the alias the catalog default (default true)
//   pollSeconds: re-probe interval in seconds (default 60)

type ServerEntry = {
  id: string
  nCtx?: number
  input?: string[]
  output?: string[]
  loaded: boolean
}

type ModelsResponse = {
  data?: Array<{
    id?: string
    meta?: { n_ctx?: number }
    architecture?: { input_modalities?: string[]; output_modalities?: string[] }
    status?: { value?: string }
  }>
}

export default Plugin.define({
  id: "auto-context",
  async setup(ctx) {
    const providerID =
      typeof ctx.options.providerID === "string" ? ctx.options.providerID : "strata"
    const endpoint =
      (typeof ctx.options.endpoint === "string" ? ctx.options.endpoint : undefined) ??
      process.env.STRATA_ENDPOINT ??
      "https://strata.ai.chrisdell.info/v1"
    const stableID =
      typeof ctx.options.stableID === "string" ? ctx.options.stableID : "qwen3.8-flash-next-ud-iq4-xs"
    const setDefault = ctx.options.setDefault !== false
    const pollMs = Math.max(5, Number(ctx.options.pollSeconds ?? 60)) * 1000
    const modelsURL = `${endpoint.replace(/\/+$/, "")}/models`

    // providerID -> detected inventory. Mutated in place; read synchronously
    // by the transforms below.
    const detected = new Map<string, ServerEntry[]>()

    const toInfo = (id: string, entry: ServerEntry) => {
      const info = Model.Info.default(Provider.ID.make(providerID), Model.ID.make(id)) as any
      // The alias keeps its catalog ID but sends requests as the loaded model.
      info.modelID = entry.id
      if (id !== stableID) info.name = entry.id
      info.capabilities = {
        ...info.capabilities,
        tools: true,
        input: entry.input ?? ["text"],
        output: entry.output ?? ["text"],
      }
      if (entry.nCtx !== undefined) info.limit.context = entry.nCtx
      return info
    }

    const modelsFor = (entries: readonly ServerEntry[]) => {
      const models: any[] = entries.map((entry) => toInfo(entry.id, entry))
      const primary = entries.find((entry) => entry.loaded) ?? entries[0]
      if (stableID && primary && !entries.some((entry) => entry.id === stableID)) {
        models.push(toInfo(stableID, primary))
      }
      return models
    }

    const probe = async (): Promise<boolean> => {
      let changed = false
      try {
        const response = await fetch(modelsURL, { signal: AbortSignal.timeout(5000) })
        if (!response.ok) return false
        const body = (await response.json()) as ModelsResponse
        const entries: ServerEntry[] = (body.data ?? [])
          .filter((entry) => typeof entry?.id === "string" && entry.id.length > 0)
          .map((entry) => ({
            id: entry.id as string,
            ...(typeof entry.meta?.n_ctx === "number" && entry.meta.n_ctx > 0
              ? { nCtx: Math.floor(entry.meta.n_ctx) }
              : {}),
            ...(Array.isArray(entry.architecture?.input_modalities)
              ? { input: entry.architecture?.input_modalities }
              : {}),
            ...(Array.isArray(entry.architecture?.output_modalities)
              ? { output: entry.architecture?.output_modalities }
              : {}),
            loaded: entry.status?.value === "loaded",
          }))
        if (entries.length === 0) return false
        const previous = detected.get(providerID)
        const same =
          previous !== undefined &&
          previous.length === entries.length &&
          previous.every(
            (old, i) =>
              old.id === entries[i].id &&
              old.nCtx === entries[i].nCtx &&
              old.loaded === entries[i].loaded,
          )
        if (!same) {
          detected.set(providerID, entries)
          changed = true
        }
      } catch {
        // Server unreachable right now; keep the last known inventory and retry next poll.
      }
      return changed
    }

    await ctx.provider.transform((editor) => {
      const entries = detected.get(providerID)
      if (!entries) return
      editor.add({
        info: {
          ...Provider.Info.empty(Provider.ID.make(providerID)),
          name: providerID,
          activation: "enabled",
          package: "@opencode/ai/providers/openai-compatible",
          settings: { baseURL: endpoint, provider: providerID, apiKey: "" },
        } as any,
        models: modelsFor(entries) as any,
      })
    })

    await ctx.model.transform((editor) => {
      if (!setDefault) return
      const models = editor.list(providerID)
      if (models.length === 0) return
      const target = models.find((model) => model.id === stableID) ?? models[0]
      const current = editor.default.get()
      if (current?.providerID === providerID && current.modelID === target.id) return
      editor.default.set(providerID, target.id)
    })

    // Force one registry rebuild so the transforms run at least once (they
    // register the detected inventory and set the default).
    await ctx.model.list()

    const apply = async () => {
      if (await probe()) {
        await ctx.provider.reload()
        await ctx.model.reload()
      }
    }

    // The first probe can fail while the plugin runtime is still activating,
    // so retry quickly (bounded) until the server reports models.
    let retries = 0
    let fast: ReturnType<typeof setInterval> | undefined
    const applyOrRetry = () => {
      void apply().finally(() => {
        if (detected.size === 0 && ++retries < 10 && fast) return
        if (fast !== undefined) {
          clearInterval(fast)
          fast = undefined
        }
      })
    }
    fast = setInterval(applyOrRetry, 2000)
    applyOrRetry()

    const timer = setInterval(() => void apply(), pollMs)
    return () => {
      clearInterval(timer)
      if (fast !== undefined) clearInterval(fast)
    }
  },
})
