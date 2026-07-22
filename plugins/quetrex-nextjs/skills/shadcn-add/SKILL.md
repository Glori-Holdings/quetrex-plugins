---
name: shadcn-add
description: Add a shadcn/ui primitive to this Next.js project the one correct way — `pnpm dlx shadcn@latest add <component>`. Use whenever a task needs a UI primitive (button, dialog, form, table, sheet…). Primitives are GENERATED into `src/components/ui/**` and must never be hand-edited; this skill covers installing them and the wrap/compose pattern for customizing them without losing changes on regen.
allowed-tools: Bash, Read, Edit, Write, mcp__context7
---

# shadcn/ui — add & compose primitives

shadcn/ui is not a dependency you import — it copies component source into your repo. The files it writes are **generated primitives**: owned by the CLI, re-emitted on every `add`/upgrade, and therefore **off-limits to hand edits** (`src/components/ui/**` is in the project's Off-limits list). Customize by **wrapping or composing**, never by editing the generated file.

## Golden rules

1. **Only ever add via the pinned CLI** — `pnpm dlx shadcn@latest add <component>`. Never copy-paste from the docs, never `npm`/`npx`/`yarn`, never write a `components/ui/*` file by hand.
2. **Never hand-edit `src/components/ui/**`.** A future `add` or upgrade overwrites it and silently drops your change. If you catch yourself opening a file under `src/components/ui/` to change behavior — stop, and wrap it instead (below).
3. **Compose classes with `cn()`** (`clsx` + `tailwind-merge`, at `src/lib/utils.ts`), never string concatenation — so caller classes win over primitive defaults deterministically.
4. **Target internals via `data-slot`**, not by editing markup. shadcn primitives expose `data-slot="..."` on their sub-parts for exactly this.

## When to use

A task needs any UI primitive (button, input, dialog, dropdown-menu, form, table, sheet, sonner, tabs…). Reach for shadcn before hand-rolling — it ships accessible, Tailwind-v4-tokened, `data-slot`-annotated primitives that match the project's theming.

## First-time setup (only if `components.json` is absent)

```bash
# One-time per repo. Initializes components.json, aliases, and cn() at src/lib/utils.ts.
pnpm dlx shadcn@latest init
```

`components.json` must already reflect this project's layout: TypeScript, RSC on, Tailwind v4 (CSS variables), and the `@/components` / `@/lib/utils` aliases resolving under `src/`. If it exists, skip init — do not re-run it.

## Add a component

```bash
# Single primitive
pnpm dlx shadcn@latest add button

# Several at once
pnpm dlx shadcn@latest add dialog form input label

# Non-interactive (agent/CI) — accept the default overwrite prompt deterministically
pnpm dlx shadcn@latest add table --yes
```

After adding:

- Files land in `src/components/ui/<component>.tsx`. **Read them to learn the API and the `data-slot` names — do not modify them.**
- The CLI auto-installs any Radix/peer deps and may touch `globals.css` (tokens) — that's expected; review the diff.
- If unsure of the exact component name or a prop, confirm against current shadcn docs via Context7 rather than guessing.

## Customize by wrapping / composing — the only sanctioned pattern

Put project-specific variants and defaults in a **new** file (e.g. `src/components/<feature>/…` or `src/components/ui-ext/…`), importing the generated primitive:

```tsx
// src/components/ui-ext/loading-button.tsx  (NOT under src/components/ui)
'use client'
import { Button, type ButtonProps } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { Loader2 } from 'lucide-react'

export function LoadingButton({
  loading,
  className,
  children,
  disabled,
  ...props
}: ButtonProps & { loading?: boolean }) {
  return (
    <Button
      className={cn('gap-2', className)} // caller classes still win via tailwind-merge
      disabled={disabled ?? loading}
      {...props}
    >
      {loading && <Loader2 className="size-4 animate-spin" aria-hidden />}
      {children}
    </Button>
  )
}
```

Restyle a sub-part through its `data-slot` from a consumer, still without touching the primitive:

```tsx
<Card className="[&_[data-slot=card-header]]:bg-muted/40" />
```

If a variant is broadly reused, add it as a new `cva` variant in your **wrapper**, or extend tokens in `globals.css` (`@theme inline`) — never inside `src/components/ui/*`.

## Client boundary

Interactive primitives (dialog, dropdown, form, tabs, sheet…) are `"use client"`. Keep that boundary at the leaf: import them into small client components, and pass Server Components in through `children`/props — don't mark a whole `page.tsx`/`layout.tsx` client just to render one.

## Regenerating / upgrading

To pull upstream fixes, re-run `add` for the affected primitive (or `pnpm dlx shadcn@latest add <c> --overwrite`). Because all your changes live in wrappers, regen is safe and loses nothing. If a diff shows edits inside `src/components/ui/*` that you didn't intend, that's a hand-edit that will be lost — move it to a wrapper before regenerating.

## Verify

Adding primitives pulls new imports/deps, so before finishing run the project chain: `pnpm verify` (tsc → eslint → format → next build → …). A new `"use client"`/server-import mismatch surfaces at `next build`.
