---
paths: ["app/**", "src/app/**", "src/components/**", "components/**", "src/lib/queries/**", "src/lib/get-query-client.ts", "src/stores/**"]
---

# Frontend conventions — RSC boundary, styling, motion, state

> **PREFER, not mandate.** These are the defaults the architect reaches for when a
> task warrants them; a simple page that needs none of TanStack Query, Zustand, or
> Framer Motion is *correct* using none. What follows is enforced **only when the
> relevant tool is actually used** — a Server Component that just renders props owes
> nothing here. The boundary rules (§1) are the exception: they always hold, because
> `import 'server-only'` + `next build` enforce them mechanically for every route.

The mental model is one line: **default to the server; `"use client"` is a leaf-level
opt-in.** Everything below flows from that.

---

## 1. Server/Client boundary (always-true — `next build` enforces it)

**Server Component by default.** A file is a Server Component unless it opens with
`"use client"`. Reach for `"use client"` **only** for: event handlers (`onClick`,
`onSubmit`), React hooks (`useState`/`useEffect`/`useRef`), browser APIs
(`window`/`localStorage`/`IntersectionObserver`), or Framer Motion. Nothing else.

**Push the boundary DOWN to the leaf.** `"use client"` at the top of a
`page.tsx`/`layout.tsx` is almost always a mistake — it drags the entire subtree to
the client and forfeits server rendering. Move the directive onto the one interactive
button/form/toggle that needs it.

```tsx
// DON'T — whole page becomes a client bundle for one button
"use client"
export default function ProductPage() {
  const [open, setOpen] = useState(false)
  return <article>{/* ...tons of static content... */}<Buy onClick={() => setOpen(true)} /></article>
}
```

```tsx
// DO — page stays a Server Component; only the button is a client leaf
export default async function ProductPage() {
  const product = await getProduct()           // server data, no client fetch
  return <article>{/* static server-rendered content */}<AddToCartButton id={product.id} /></article>
}
// components/add-to-cart-button.tsx
"use client"
export function AddToCartButton({ id }: { id: string }) {
  const [pending, start] = useTransition()
  return <button onClick={() => start(() => addToCart(id))} disabled={pending}>Add to cart</button>
}
```

**Keep Server Components inside client trees via composition, never import.** You may
not `import` a Server Component into a `"use client"` file (it silently becomes a
Client Component). Instead pass it through the `children`/props slot:

```tsx
// DO — <ServerList/> renders on the server, slotted into the client shell
<ClientTabs>
  <ServerList />        {/* stays a Server Component */}
</ClientTabs>
```

**Guard server-only modules** so an accidental client import is a **build error**, not
a leaked secret or a runtime surprise. Any module touching the DB, secrets, or
`process.env` starts with `import 'server-only'`:

```ts
// src/db/index.ts
import 'server-only'
import { db } from './client'   // now importing this from a "use client" file fails `next build`
```

- DON'T read `process.env` in a component — use the validated `src/env.ts` module.
- DON'T pass non-serializable values (functions other than Server Actions, class
  instances, Dates-in-Maps) across the `"use client"` boundary as props — `next build`
  rejects it.
- DO fetch on the server and hand data down as props or via a hydration boundary (§4).

*Enforcement:* `import 'server-only'` + `next build` in `pnpm verify` catch every
boundary violation authoritatively. There is deliberately **no regex hook** for this.

---

## 2. Styling — Tailwind v4 (CSS-first) + shadcn/ui

**Tailwind v4 is CSS-first.** Design tokens are CSS variables declared in
`globals.css` and exposed to utilities via `@theme inline`; colors are `oklch()`.
There is **no color palette in a `tailwind.config`** (that is the legacy v3 model).
Dark mode is a `.dark` class toggled by `next-themes`.

```css
/* globals.css */
@import "tailwindcss";
@theme inline {
  --color-brand: oklch(0.62 0.19 256);
  --color-bg: var(--background);
}
:root { --background: oklch(1 0 0); }
.dark { --background: oklch(0.18 0.02 256); }
```

- DON'T add a `colors: {...}` block to a `tailwind.config.*` — define tokens as CSS
  variables and surface them through `@theme inline`.
- DON'T hardcode hex/rgb in class names when a token exists (`bg-[#4f46e5]` → `bg-brand`).

**Never hand-edit `components/ui/*` (shadcn primitives).** They are generated and get
**overwritten on regeneration**. To change one: **wrap or compose** it, and target
internals via the `data-slot` attribute, never by editing the source.

```tsx
// DON'T — edits vanish next time the primitive is regenerated
// components/ui/button.tsx  ← hand-modified

// DO — compose a project button on top of the primitive
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
export function CtaButton({ className, ...props }: React.ComponentProps<typeof Button>) {
  return <Button className={cn("shadow-lg", className)} {...props} />
}
```

**Add primitives with the pinned command, not by hand:** `pnpm dlx shadcn@latest add
<component>` (see the `shadcn-add` skill). **Compose class names with `cn()`**
(clsx + tailwind-merge) so conditional and overriding classes merge correctly instead
of both landing in the DOM.

```tsx
// DON'T — string concat: "px-2 px-4" both survive, last-wins is not guaranteed
<div className={`p-2 ${active ? "p-4" : ""}`} />
// DO — tailwind-merge dedupes conflicting utilities
<div className={cn("p-2", active && "p-4")} />
```

---

## 3. Motion — Framer Motion via `motion/react` + LazyMotion

**Import from `motion/react`** (not the legacy `framer-motion` entry). Every file that
animates is a client leaf (`"use client"`) — motion needs hooks.

**One `LazyMotion` provider near the root, then lightweight `m.*` components.** This
ships ~5kb instead of ~34kb by lazy-loading the feature bundle once.

```tsx
// app/providers.tsx (client)
"use client"
import { LazyMotion, domAnimation } from "motion/react"
export function MotionProvider({ children }: { children: React.ReactNode }) {
  return <LazyMotion features={domAnimation} strict>{children}</LazyMotion>
}
```

```tsx
// a motion leaf
"use client"
import { m } from "motion/react"          // DO: m.* under LazyMotion
// import { motion } from "motion/react"  // DON'T: pulls the full ~34kb bundle
export function FadeIn({ children }: { children: React.ReactNode }) {
  return <m.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}>{children}</m.div>
}
```

- DO set `initial={false}` on SSR'd / above-the-fold content so it doesn't flash or
  re-animate on hydration.
- DO animate **only `transform` and `opacity`** (GPU-composited); animating
  `width`/`height`/`top`/`left`/`box-shadow` thrashes layout.
- DO respect `useReducedMotion()` — gate or shrink animations when the user opts out.
- With `strict` on the provider, `motion.*` throws — that's intentional; use `m.*`.

*Reach for motion only when a task calls for it.* Most UI needs none; a CSS transition
is often the right, zero-JS answer.

---

## 4. State — TanStack Query (server state) vs Zustand (client/UI state)

**Split state by kind. Never mix the two, never mirror one into the other.**

| Kind of state | Owner |
|---|---|
| Anything fetched / async / cached / server-derived | **TanStack Query** |
| Ephemeral client-only UI (modal open, active tab, filter draft, sidebar) | **Zustand** (or local `useState`) |
| Static request-time data | **RSC → props** (no library) |

- DON'T copy fetched data into Zustand or `useState` — TanStack Query is the cache;
  duplicating it creates two sources of truth that drift.
- DON'T fetch in `useEffect` when the data could be prefetched on the server.
- DON'T put server-derived data in a Zustand store.

### TanStack Query — the two rules that matter

**(a) Non-zero `staleTime`.** With the default `staleTime: 0`, every server-prefetched
query is stale on mount and **refetches immediately on hydration**, throwing away the
SSR render. Set a sane default in the shared client:

```ts
// src/lib/get-query-client.ts — per-request client on the server, singleton in the browser
import { QueryClient, defaultShouldDehydrateQuery, isServer } from "@tanstack/react-query"
function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: { staleTime: 60_000 },   // DO: non-zero — SSR'd data isn't instantly refetched
      dehydrate: {
        shouldDehydrateQuery: (q) =>
          defaultShouldDehydrateQuery(q) || q.state.status === "pending", // stream pending queries
      },
    },
  })
}
let browserQueryClient: QueryClient | undefined
export function getQueryClient() {
  if (isServer) return makeQueryClient()
  return (browserQueryClient ??= makeQueryClient())
}
```

**(b) One `queryOptions()` factory per query — shared by server prefetch AND client
hook**, so the query key can never drift between the two sides:

```ts
// src/lib/queries/todos.ts
import { queryOptions } from "@tanstack/react-query"
import { getTodos } from "@/lib/api/todos"
export function todosQueryOptions(status: string) {
  return queryOptions({
    queryKey: ["todos", { status }] as const,   // ONE key definition, imported everywhere
    queryFn: () => getTodos(status),
  })
}
```

- DON'T write inline `useQuery({ queryKey: ["todos"], ... })` scattered across files —
  keys drift, invalidation misses, prefetch and hook disagree.
- DON'T `await prefetchQuery` when you want streaming — omit `await` so the pending
  query streams and the shell renders immediately.

**RSC → client handoff:** prefetch on the server (no `await` = non-blocking), then
`dehydrate` into a `<HydrationBoundary>`; the client leaf calls
`useSuspenseQuery(sameOptions)` and fetches **zero** times on hydration:

```tsx
// app/todos/page.tsx (Server Component)
import { dehydrate, HydrationBoundary } from "@tanstack/react-query"
import { getQueryClient } from "@/lib/get-query-client"
import { todosQueryOptions } from "@/lib/queries/todos"
import { TodoList } from "./todo-list"
export default function Page() {
  const qc = getQueryClient()
  void qc.prefetchQuery(todosQueryOptions("open"))    // no await → streams
  return (
    <HydrationBoundary state={dehydrate(qc)}>
      <TodoList status="open" />
    </HydrationBoundary>
  )
}
```

```tsx
// app/todos/todo-list.tsx (client leaf — same options object, same key)
"use client"
import { useSuspenseQuery } from "@tanstack/react-query"
import { todosQueryOptions } from "@/lib/queries/todos"
export function TodoList({ status }: { status: string }) {
  const { data } = useSuspenseQuery(todosQueryOptions(status))  // hydrates, refetches 0 times
  return <ul>{data.map((t) => <li key={t.id}>{t.title}</li>)}</ul>
}
```

### Zustand — ephemeral UI only

Stores hold **only** transient client UI state (modal/drawer open, active tab, filter
draft, wizard step). Keep them small and colocated in `src/stores/*`.

```ts
// DO — a store for ephemeral UI
import { create } from "zustand"
export const useUiStore = create<{ sidebarOpen: boolean; toggle: () => void }>((set) => ({
  sidebarOpen: false,
  toggle: () => set((s) => ({ sidebarOpen: !s.sidebarOpen })),
}))
```

```ts
// DON'T — server data does not belong in a store
export const useUsers = create((set) => ({ users: [], load: async () => set({ users: await fetch(...) }) }))
// ↑ this is TanStack Query's job — use todosQueryOptions/useQuery instead
```

---

## Quick reference

- Default to Server Components; `"use client"` only for handlers/hooks/browser
  APIs/motion — and put it on the **leaf**, not the page.
- `import 'server-only'` in every DB/secret/env module; never read `process.env` in
  components (use `src/env.ts`).
- Tailwind v4 tokens as CSS vars via `@theme inline` (`oklch`); never hand-edit
  `components/ui/*` — compose and target `data-slot`; merge classes with `cn()`.
- Motion: `motion/react` + one `LazyMotion` + `m.*`; animate transform/opacity only;
  `initial={false}` on SSR'd content; respect `useReducedMotion()`.
- Server/async data → TanStack Query (non-zero `staleTime`, `queryOptions()` factory,
  prefetch → `HydrationBoundary` → `useSuspenseQuery`). Ephemeral UI → Zustand/`useState`.
  Never mirror one into the other.
