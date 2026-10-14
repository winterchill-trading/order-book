# AGENTS.md (test/)

Expect tests, Base_quickcheck properties and allocation checks for `Order_book`.

- `naive_book.ml` is a sorted-list reference matcher. `test_bisim.ml` checks that fills,
  status, remainder, cancel results and the full L2 agree after every operation. A change in
  matching semantics must change both sides on purpose.
- `helpers.ml` and `op.ml` build the random operation sequences used by the properties.
- `test_alloc.ml` pins minor and major words per operation. A pin that moves is either a real
  regression or a platform difference; check the comment next to the pin before editing it.
- Promote expect output with `dune promote <file>` for the one file that changed.

Run: `opam exec --switch 5.2.0+ox -- dune build --root .. @order-book/runtest`.
