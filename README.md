# Quetrex Plugins

The private Claude Code plugin marketplace for the Quetrex engine.

This repo is the marketplace for the Quetrex plugin family — **three plugins** plus stack
packs, each scoped to where it belongs:

- **`quetrex-setup`** — install **once per machine**, at **user scope**. Ships
  `/quetrex-setup:login`, `/quetrex-setup:init`, and `/quetrex-setup:update`, plus a
  one-line `SessionStart` offer to arm any git repo that isn't yet a Quetrex project. Carries
  no gates and no build engine — it only ever configures other repos.
- **`quetrex`** — the kanban commands (`task-new`, `task-refine`, `task-build`,
  `task-rework`, `task-complete`, `merge`, `deploy`, `doctor`). **Project-scoped only**,
  enabled per repo by `/quetrex-setup:init`.
- **`quetrex-factory`** — the guarded agent pipeline itself (architect → developer(s) → QA →
  preview+E2E → reviewer → git-workflow) whose four pillars are guaranteed by **hooks and
  on-disk artifacts a hook reads**, never by an agent's prose. **Project-scoped only**,
  enabled per repo by `/quetrex-setup:init`. Its source of truth (agents, hooks, scripts)
  lives in `Glori-Holdings/quetrex-base` at `plugins/quetrex-factory/`; this repo's
  `.claude-plugin/marketplace.json` sources it from there via a `git-subdir` reference so
  there is exactly one copy of the floor scripts, never a second one published here.

Stack packs (**`quetrex-nextjs`** ships today; `quetrex-python`, `quetrex-rust`,
`quetrex-swift` are on the roadmap) layer stack-specific agents/checks on top of
`quetrex-factory`. Also project-scoped.

- **Excellent code** — `verify-gate` (Stop + SubagentStop) binds "done" to the real exit
  codes of your project's verify chain. It blocks any finish while typecheck / lint /
  build / tests are red, and writes the commit `sha` on every ledger line so the merge gate
  can commit-pin green to the PR head. Red genuinely cannot be reported as done.
- **Solid process** — an artifact-gated state machine with bounded (≤3) remediation loops.
  A clean review **auto-merges with no human**; issues re-enter as `REWORK`; risky diffs
  `ESCALATE_HUMAN` to a human who merges on GitHub. The **only** manual gate is a
  production deploy.
- **Security** — a mandatory-by-detection `/security-review` pass (OWASP checklist) inside
  the fresh-context reviewer; a CONFIRMED **Critical** hard-blocks the merge.
- **Speed** — a deterministic `right-size-router` sends trivial work down a single
  direct-edit path and only pays the full pipeline when the change warrants it.

The reviewer runs in a **fresh context**, driving the native `/review` and `/security-review`
commands and writing `.quetrex/review-verdict.json` with a verdict of `AUTO_MERGE`,
`REWORK`, or `ESCALATE_HUMAN` — the sole authority the `merge-gate` hook consults. Before
review, agents deploy the branch to an **ephemeral preview** (Fly.io primary via a per-branch
app on a seeded Neon branch; Vercel secondary) and run E2E against the live preview; teardown
is mandatory.

> **Marketplace name:** `quetrex`
> **Source repo:** `github.com/Glori-Holdings/quetrex-plugins` (**private**)

---

## Install once per machine

Before touching any repo, install **`quetrex-setup`** — it's the only plugin that belongs
at **user scope**, and it's how you bootstrap everything else.

```bash
claude plugin marketplace add Glori-Holdings/quetrex-plugins
claude plugin install quetrex-setup@quetrex   # user scope is the default
```

Then authenticate to the kanban:

```
/quetrex-setup:login
```

That's the whole one-time machine setup. From here, arm each repo you work in with
`/quetrex-setup:init` (§2) — never install `quetrex`, `quetrex-factory`, or a stack pack at
user scope yourself; doing so runs their build gates against every repo you open, armed or
not.

---

## How a project adopts Quetrex

Adoption is **two independent pieces**. Both are required; neither can substitute for the
other.

| Piece | Set by | Lives in | Why it can't move |
|---|---|---|---|
| **1. AUTO permission mode** | each developer, once per machine/account | **their own** `~/.claude/settings.json` | `permissions.defaultMode` is honored **only** in user settings (see below) |
| **2. Plugin pin** | the repo, checked into git | the repo's `.claude/settings.json` | travels with the code so every clone + every cloud session gets the same engine |

Do both once and every session on that repo runs the full guarded pipeline.

---

## 1. Each developer sets AUTO mode in their OWN user settings

The Quetrex team runs Claude Code in **auto** permission mode — `--permission-mode auto`
(equivalently `permissions.defaultMode: "auto"`). This is what lets the pipeline run
overnight, unattended, without a human clicking "allow" on every step. It is **not** a
blanket permission bypass — every guard hook still fires in auto mode (see below).

**Critical platform fact:** `permissions.defaultMode` is honored **only** when it appears
in the user-level `~/.claude/settings.json` (or in managed settings — see §4). Since
Claude Code **v2.1.142**, a `defaultMode` set in **project** `.claude/settings.json` or in
**plugin** settings is **silently ignored**. That is a deliberate safety rule: a repo you
clone cannot quietly grant itself elevated autonomy on your machine.

**Therefore the plugin cannot turn on auto mode for you.** Each developer must set it
themselves. Add this to your **`~/.claude/settings.json`** (create the file if it doesn't
exist):

```json
{
  "permissions": {
    "defaultMode": "auto"
  }
}
```

If you already have a `~/.claude/settings.json`, merge the `permissions.defaultMode` key
in — don't clobber your existing settings.

Verify it took effect:

```bash
claude --version            # ensure >= 2.1.142
# then, inside a session, the status line / `/status` should report permission mode: auto
```

### Auto mode does NOT weaken the guardrails

Every Quetrex guard still fires under auto mode, because a **blocking hook runs before
permission rules are consulted**, and the permission **deny-list** is always evaluated:

- `PreToolUse` hooks — `deny-guard`, `secret-scan`, `enforce-branch`, `merge-gate`
- `Stop` / `SubagentStop` hooks — `verify-gate`
- the `permissions.deny` list — destructive-command blocks

Auto mode only removes the interactive **allow** prompt for routine, already-permitted
actions. It cannot bypass a hook that returns a `deny` / `block` decision. Red still can't
ship; secrets still can't be written; merges still require the artifact gate.

---

## 2. Pin the plugins in the repo's checked-in `.claude/settings.json`

Commit this file at the **repo root** as `.claude/settings.json`. It travels with the
code, so every clone — and every claude.ai/code cloud session (§3) — loads the exact same
engine. **`/quetrex-setup:init`** (from the machine-wide plugin installed in the previous
section) writes this file for you, merging non-destructively into whatever is already
there. The rest of this section shows exactly what it writes, for reference or manual
repair.

Two keys do the work:

- `extraKnownMarketplaces` — teaches Claude Code where the `quetrex` marketplace lives.
- `enabledPlugins` — turns the plugins on for this repo, as **booleans only** (never a
  version string or array — see "No version pins" below).

### Standard repo (any stack)

```json
{
  "extraKnownMarketplaces": {
    "quetrex": {
      "source": {
        "source": "github",
        "repo": "Glori-Holdings/quetrex-plugins"
      }
    }
  },
  "enabledPlugins": {
    "quetrex@quetrex": true,
    "quetrex-factory@quetrex": true,
    "quetrex-setup@quetrex": true
  }
}
```

### Next.js repo (adds the stack overlay)

Add `quetrex-nextjs` on top — it layers Next.js-specific agents/checks on top of the
stack-agnostic `quetrex-factory` base, so keep all four entries:

```json
{
  "extraKnownMarketplaces": {
    "quetrex": {
      "source": {
        "source": "github",
        "repo": "Glori-Holdings/quetrex-plugins"
      }
    }
  },
  "enabledPlugins": {
    "quetrex@quetrex": true,
    "quetrex-factory@quetrex": true,
    "quetrex-setup@quetrex": true,
    "quetrex-nextjs@quetrex": true
  }
}
```

> **Do NOT put `defaultMode` in this file.** As covered in §1, project-level `defaultMode`
> is ignored since v2.1.142. Auto mode is a per-developer user setting only.

### First open

When a developer opens the repo, Claude Code sees the pinned marketplace + plugins and
prompts once to trust and install them. After that it's silent on every subsequent session.

### No version pins

Never set an `enabledPlugins` value to anything but `true`. A version string or array —
e.g. `"quetrex-factory@quetrex": "1.4.0"` or `["1.4.0"]` — makes the plugin count as
**disabled** for dependency resolution, and the whole `/quetrex:*` command layer fails to
load silently, even when the pinned version is the exact one installed. There is no way to
pin a release through this file; the engine auto-updates from the marketplace and the
running version is surfaced in the status bar, never in config.

---

## 3. Works locally AND in claude.ai/code (cloud)

The checked-in `.claude/settings.json` from §2 is read **identically** by local Claude Code
and by cloud sessions on **claude.ai/code** — the plugin pin travels with the repo either
way. Two cloud-specific requirements:

1. **Private-marketplace access via the GitHub proxy.** `Glori-Holdings/quetrex-plugins`
   is private, so a cloud environment can only clone it through Anthropic's GitHub proxy.
   The account running the cloud session must have its **GitHub connected** with access to
   the **`Glori-Holdings`** org (grant the org during the GitHub App authorization in your
   claude.ai settings). Without that grant the cloud session cannot fetch the marketplace
   and the plugin won't install. Locally, your normal `git`/`gh` credentials with org
   access are sufficient — no proxy involved.

2. **Auto mode in the cloud is a per-environment setting**, not something the repo can
   grant (same v2.1.142 rule as §1). Set the environment's permission mode to **auto** in
   your claude.ai/code environment configuration so unattended runs don't stall on
   prompts.

Everything else — the agents, the guard hooks, the verify-gate, the router — behaves the
same in both places, because they all ship inside the plugin and reference themselves via
`${CLAUDE_PLUGIN_ROOT}`.

---

## 4. Team / Enterprise: the managed-settings floor

For orgs on **Team** or **Enterprise**, an admin can push a **managed settings** file that
is a **mandatory, non-overridable floor** — higher precedence than any user or project
`settings.json`. Use it to guarantee the four non-negotiable guards fire for **every**
teammate, on every repo, even if someone edits their own settings or tries a more permissive
permission mode.

Managed settings can *also* set `defaultMode: "auto"` org-wide, which removes the per-dev
step in §1 entirely — a managed `defaultMode` **is** honored (unlike a project one).

**File location** (deploy via MDM / config management):

| OS | Path |
|---|---|
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` |
| Linux / WSL | `/etc/claude-code/managed-settings.json` |
| Windows | `C:\ProgramData\ClaudeCode\managed-settings.json` |

**Contents** — the four floor guards + the destructive-command deny-list + org-wide auto,
with `allowManagedHooksOnly` so only managed/plugin hooks run (a teammate can't register a
competing or hook-disabling local hook):

```json
{
  "permissions": {
    "defaultMode": "auto",
    "deny": [
      "Bash(rm -rf /)",
      "Bash(rm -rf ~)",
      "Bash(git push --force:*)",
      "Bash(git reset --hard:*)"
    ]
  },
  "allowManagedHooksOnly": true,
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/deny-guard.sh", "timeout": 5000 },
          { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/secret-scan.sh", "timeout": 5000 },
          { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/merge-gate.sh", "timeout": 5000 }
        ]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [
          { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/secret-scan.sh", "timeout": 5000 }
        ]
      }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/verify-gate.sh", "timeout": 600000 } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/verify-gate.sh", "timeout": 600000 } ] }
    ]
  }
}
```

The floor is exactly: **verify-gate** (Stop + SubagentStop), **secret-scan** (Write/Edit +
Bash), **deny-guard**, **merge-gate**. Everything else the plugin ships — the
router, `enforce-branch` (which uses `ask`, not `deny`, so a human can override), and
`format-on-save` — stays plugin-level and project-tunable.

> `allowManagedHooksOnly: true` forces Claude Code to run only hooks defined in managed
> settings **and installed plugins** — user/project `settings.json` hooks are ignored. That
> converts the four pillars from prompt guidance into mechanical guarantees no teammate can
> silently disable.

If you are **not** on Team/Enterprise, skip this section: §1 (per-dev auto) + §2 (repo pin)
give you the full pipeline; the plugin still ships and wires all its guards. The managed
floor only adds *undisableable* enforcement.

---

## Verify the install

After opening a repo that pins the plugin:

```bash
# 1. plugins are enabled from the quetrex marketplace
claude plugin list           # expect: quetrex@quetrex, quetrex-factory@quetrex (enabled)

# 2. hooks are wired (from the plugin + any managed floor)
#    inside a session:
/hooks                       # expect verify-gate on Stop/SubagentStop,
                             # deny-guard/secret-scan/merge-gate/enforce-branch on PreToolUse

# 3. permission mode is auto (per §1 or §4)
/status                      # expect: permission mode: auto
```

A quick end-to-end smoke test: ask for a one-line docs edit — the router should print
`ROUTE: TRIVIAL` and finish through a single direct-edit agent, and the `verify-gate` still
runs the project's verify chain before the session is allowed to stop.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Sessions still prompt for every action | `defaultMode` set in project settings (ignored since v2.1.142) | Move it to `~/.claude/settings.json` (§1) or managed settings (§4) |
| Cloud session can't install the plugin | GitHub proxy has no access to the private `Glori-Holdings` org | Connect GitHub + grant the `Glori-Holdings` org in claude.ai settings (§3) |
| Plugin not found / marketplace unknown | `extraKnownMarketplaces` missing or wrong repo slug | Ensure the repo `.claude/settings.json` matches §2 exactly (`Glori-Holdings/quetrex-plugins`) |
| A teammate disabled a guard | No managed floor in place | Deploy managed settings with `allowManagedHooksOnly` (§4) |
| `/quetrex:*` commands don't exist in a repo that should have them | `enabledPlugins` has a version-string or array pin, which counts as disabled | Remove the pin — booleans only (§2, "No version pins") |
| A `quetrex`, `quetrex-factory`, or stack-pack entry at **USER** scope (`~/.claude/settings.json`) | Installed machine-wide instead of per repo | Remove it — only `quetrex-setup` belongs at user scope ("Install once per machine" above); `/quetrex:doctor` Check 10 flags this |

---

## Repo layout

```
.claude-plugin/marketplace.json   # marketplace manifest: name "quetrex", owner, plugins[]
plugins/
  quetrex-nextjs/                 # Next.js overlay on top of quetrex-factory
README.md                         # this file
```

Neither `quetrex-factory` nor `quetrex-setup` lives in this repo — both are sourced by
`.claude-plugin/marketplace.json` straight from `Glori-Holdings/quetrex-base`'s
`plugins/quetrex-factory/` and `plugins/quetrex-setup/` via `git-subdir` sources, so each
engine has exactly one copy (quetrex-base) rather than a synced duplicate here. The
`quetrex` marketplace is defined by `.claude-plugin/marketplace.json`; each entry in its
`plugins[]` array names a plugin, its `source` (a local path for the stack packs, a
`git-subdir` reference into quetrex-base for `quetrex-factory` and `quetrex-setup`, and
`github` for the top-level `quetrex` plugin), and a `version`. A project's `enabledPlugins`
value of `quetrex-factory@quetrex` resolves through that manifest.
