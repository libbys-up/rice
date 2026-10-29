Plan: case shortcutting (`RET`)
===============================

Moved here from `src/archetecture.md` (now replaced by
`src/developers-manual.tex`). The design comes from old_rice and its
dissertation (chapter 7). Nothing here is implemented yet; the placeholders
are `Symbol.hnf_RET` in `runtime/node.h` and `make_restore` in
`runtime/runtime.h`.

## The idea

In

```
case x || y of
  True  -> ...
  False -> ...
```

we don't need a node for `x || y`, only its result. So instead of allocating
one, we evaluate it in a single static node, `RET`, and look at `RET`'s tag
afterwards. This works because cases never partially overlap, so `RET` never
stands for two expressions at once.

The trouble is nondeterminism: if the scrutinee depends on a choice,
something has to go on the trail, and it can't be `RET`.

## Three attempts that don't work

These are the bugs a first implementation will hit.

1. **Naive**: store the value in `RET` and evaluate it as usual. Fine for
   deterministic code, but if `RET` is nondeterministic, the trail entry
   points *at* `RET`, which will have been reused by the time we backtrack.
2. **Copy on backtrack**: when nondeterministic, copy `RET` into a fresh heap
   node and trail that. Still broken: (a) if `RET` is a FORWARD, its target
   can be nondeterministic before `RET` looks nondeterministic; (b) evaluating what `RET`
   forwards to can reuse `RET` before the copy happens; (c) if the original
   expression was stored in `RET` nondeterministically, `RET` still ends up as
   the left-hand side of a trail entry.
3. **What works**: give every function `f` that can be a `RET` scrutinee a
   second entry point, `f_RET_hnf(Node* backup)`, with an explicit `backup`
   node. It fills `backup` with `RET`'s contents before the reduction only if
   the reduction turns out nondeterministic, allocating it then if it was
   `NULL`, and returns it. The backup is an ordinary local, immune to `RET`
   being reused; it's only allocated when something has to go on the trail;
   and it's passed down through nested `RET` evaluations, so a whole chain
   shares one allocation, made only if a choice shows up.

## What it buys

With unboxing, a worker/wrapper split and shortcutting, old_rice's `fib`
allocated nothing for its recursive calls: constant space instead of
exponential.

## What the compiler needs

- An analysis marking every expression used only as a case scrutinee (a
  `let`-bound variable used once, as a scrutinee). This is a whole-body
  analysis, not a peephole rule; nothing in `Rice.Optimize` does it yet.
- A `f_RET_hnf` variant for every function that can appear there.
- In the evaluation machine, `RET` would have to live in a frame or be
  treated as a GC root; the old design predates the machine and the
  collector.
