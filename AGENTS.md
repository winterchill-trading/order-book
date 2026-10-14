# AGENTS.md

Guide for AI coding agents working in this repository. Read this first; the subdirectory
`AGENTS.md` files add detail for `lib/`, `test/`, `bench/`, `examples/` and `.github/`.
The workspace-wide guide is `../oxcaml-claude-skills/AGENTS.md`.

## Purpose

`order-book` is a price-time priority limit order book with matching, for one instrument.
It is pure and mutable: no I/O, no margin or account checks. Callers validate and risk-check
before they submit, and the book returns fills, status and the L2 view.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | `Order_book` (book, `Stp`, `Resting_order`, `Status`, `Result`) and `Order_book.Fill` |
| `test/` | Expect tests, Quickcheck properties, a bisimulation test against a sorted-list reference, the fuzz property, allocation test |
| `bench/` | core_bench of a 1000-level book (`main.ml`) |
| `examples/` | `quickstart.ml`, run by `dune test` and diffed against `quickstart.expected` |
| `.github/` | CI workflow |
| `dune-project` | Source of truth for package metadata; `dune build` regenerates `order-book.opam` |
| `CHANGES.md`, `README.md`, `LICENSE` | Changelog, user docs, MIT licence |

## Build, test, docs

Inside the workspace (sibling checkouts and the shared `5.2.0+ox` switch are required):

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @order-book/all
opam exec --switch 5.2.0+ox -- dune build --root .. @order-book/runtest
opam exec --switch 5.2.0+ox -- dune build --root .. @order-book/doc
```

Parallel work: prefix the commands with `DUNE_BUILD_DIR=_build-order-book`.

Standalone: the dependencies `exchange-core` and `fixed-decimal` are not in the
`winterchill` opam repository yet, so pin them from GitHub the way `.github/workflows/ci.yml`
does (`exchange-core` first, then this repository), and then `dune build && dune test`.

## Conventions

- Every module has an `.mli`; public values carry odoc comments. Code is `open! Core`,
  labelled arguments, ppx_jane derivations.
- Performance is a contract. Hot paths are pinned by allocation counts (`test/test_alloc.ml`)
  and `[@@zero_alloc]` on `*_or_null` queries. Count major-heap words as well as minor words.
- Allocation pins differ between arm64 macOS and amd64 Linux CI. Pin an exact value per
  platform or a range that covers both, and say why in a comment next to the pin.
- Expect output is promoted one file at a time with `dune promote <file>`.
- Formatting: `opam exec --switch 5.2.0+ox -- dune build --root .. @order-book/fmt --auto-promote`.
  Never run `dune fmt` at the workspace root.
- `CHANGES.md`: add a line under `## Unreleased` for every user-visible change.

## Dependencies and dependents

- Depends on `fixed-decimal` and `exchange-core` (both pinned from GitHub in CI).
- Used by `exchange-core-engine` (in the `exchange-core` repository), `price-anchor` and the
  exchange simulators built on them.
- The package cycle is real: `exchange-core-engine` depends back on this library, so the
  primitives cannot move into `exchange-core`'s first package. Keep pins in dependency order.

## CI

`.github/workflows/ci.yml`: `ox-setup` (cached switch) with pins for `fixed-decimal` and
`exchange-core`, then `dune build`, `dune test`, `dune exec examples/quickstart.exe`, and an
odoc build in which warnings fail the job. The shared `obj-magic` workflow runs last. Check
a run with `gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`.

## Pitfalls

- Do not `open! Order_book` when it defines `Result`: the module shadows Core's `Result`.
  Use `Order_book.Fill` and the other submodules qualified.
- `[@@zero_alloc]` fails through any call into `fixed-decimal` until that library annotates
  its own functions. Check the claim with a probe that allocates on purpose, otherwise the
  check may be silently off.
- A cancel that filtered a 1000-order level allocated about 1500 words on the major heap,
  which a minor-words test does not see.
- `Order_book.iter` takes an `@ local` callback and needs `[@nontail]` at its call sites.
- `-O3` per repository buys little here; most gain came from inlining in `fixed-decimal`
  and `exchange-core`, which is built by their own CI.

## Where to read more

- `README.md`: API, design notes, portability, benchmarks, self-trade policy, known gaps.
- `../specs/repos/order-book.md`: role in the trading stack.
- `../oxcaml-claude-skills/skills/oxcaml-performance/` and `oxcaml-modes/`.
- `../oxcaml-claude-skills/GOTCHAS.md`, sections "order-book / fixed-decimal extraction"
  and "OxCaml performance".

## Never do

- Install or upgrade opam packages that change the compiler, `core`, `base`, `async` or
  `ppx_jane` on the shared switch. Run `opam install --switch 5.2.0+ox --dry-run <pkg>` first
  and stop if the plan touches any of them.
- Publish, tag or release, or add `pin-depends` or a forked copy of another package.
- Create a git worktree inside the workspace root; dune then sees duplicate packages.
- Commit credentials, print secrets, or poll CI in a loop.
