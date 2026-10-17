{ pkgs, ... }:

let
  json = pkgs.formats.json { };
in
{
  # OpenCode — the fleet-wide agent config (was ~/.config/opencode, hand-
  # maintained on zen3-nixos). This module is imported by users/cjdell/home.nix
  # (every home-manager host) and by hosts/grafton-router/home-manager.nix, so
  # every machine the flake manages gets the same config.
  #
  # What lives here vs. what does NOT:
  #
  #   - opencode.json  -> programs.opencode.settings (the pinned home-manager
  #     ships a programs.opencode module; it adds the $schema line itself).
  #   - cli.json       -> xdg.configFile below. This is the *v2* TUI settings
  #     file; home-manager's module still writes the v1-era tui.json, so this
  #     one is written by hand.
  #   - plugins/       -> xdg.configFile (the module has no plugins option;
  #     opencode auto-loads *.ts from the config dir's plugins/ folder).
  #   - skills/        -> programs.opencode.skills (directory form: symlinked
  #     whole). The 13 Brave-search skills live in ./opencode/skills.
  #   - service.json, package.json, bun.lock, node_modules, .gitignore are
  #     opencode-generated local state (service.json even holds a password) —
  #     deliberately NOT managed; opencode (re)creates them next to the
  #     symlinks.
  #   - opencode.jsonc was the stale v1 config (pointed at the retired
  #     llama-swap router) and is not reproduced.
  #
  # The BINARY stays installer-managed (~/.opencode/bin, v2 line, self-
  # updating): nixpkgs only carries opencode 1.18.x (v1), which would be a
  # downgrade and ignores cli.json — hence package = null.
  #
  # Secrets: the brave MCP server reads its key from BRAVE_API_KEY_FILE =
  # /run/secrets/brave_api_key, a sops secret declared in common/sops.nix (and
  # the router's own sops.nix), mode 0440 root:wheel. On the two hosts without
  # sops (rocketlakelatitude, 3d-printer-server) the file simply does not
  # exist: the brave MCP server fails to start there, everything else works.
  #
  # force = true below takes over the previously hand-maintained files:
  # home-manager moves any existing file/dir aside as <name>.backup-<n> and
  # links the store version. From now on, edit THIS file, not ~/.config/opencode.

  programs.opencode = {
    enable = true;
    package = null;

    settings = {
      mcp = {
        brave-search = {
          type = "local";
          command = [
            "npx"
            "-y"
            "@brave/brave-search-mcp-server"
            "--transport"
            "stdio"
          ];
          enabled = true;
          environment.BRAVE_API_KEY_FILE = "/run/secrets/brave_api_key";
        };
        # NB: v2 accepts both `mcp.<name>` and `mcp.servers.<name>`; the
        # nesting below mirrors the hand-written file this replaced.
        servers.recallium = {
          type = "remote";
          url = "https://recallium-mcp.ai.chrisdell.info/";
        };
      };

      agent = {
        # The hidden `title` agent fires a second request per new session
        # against the same single-slot Strata engine — disabled outright.
        title.disable = true;
        general = {
          mode = "subagent";
          max = 1;
        };
      };

      # Self-hosted Strata (Qwen3.8-Flash-Next on the zen3-nixos R9700),
      # reached over the public HTTPS endpoint so it works from every host.
      provider.strata = {
        models."qwen3.8-flash-next-ud-iq4-xs" = {
          _launch = true;
          tools = true;
          name = "qwen3.8-flash-next-ud-iq4-xs";
        };
        name = "strata";
        npm = "@ai-sdk/openai-compatible";
        options.baseURL = "https://strata.ai.chrisdell.info/v1";
      };
    };

    skills = ./opencode/skills;
  };

  xdg.configFile = {
    # v2 TUI settings (the file the hand-written config had).
    "opencode/cli.json" = {
      source = json.generate "opencode-cli.json" {
        "$schema" = "https://opencode.ai/v2/cli.json";
        diffs.wrap = "word";
        session = {
          sidebar = "hide";
          scrollbar = false;
          thinking = "show";
          permissions = "autoaccept";
        };
        animations = true;
      };
      force = true;
    };

    # The auto-context plugin (probes self-hosted providers' /models for
    # meta.n_ctx and overrides limit.context — see the file's header comment).
    "opencode/plugins" = {
      source = ./opencode/plugins;
      recursive = true;
      force = true;
    };

    # Take over the entries programs.opencode writes as well.
    "opencode/opencode.json".force = true;
    "opencode/skills".force = true;
  };
}
