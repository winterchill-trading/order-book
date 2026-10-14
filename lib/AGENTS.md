# AGENTS.md (lib/)

The `order-book` library, wrapped as `Order_book`.

- `order_book.ml`: the book. Each side is a map from price to a level; a level is an intrusive
  linked list in arrival order; the id index points at each order's node, so cancel is O(1).
  The best level of each side is cached.
- `fill.ml`: the taker and maker match record. Fills execute at the maker's price.
- Self-trade prevention is a per-book policy (`Stp.t`, given to `create ?stp`).
- Keep the book free of I/O and account checks. Any new policy goes in as a parameter.

Build: `opam exec --switch 5.2.0+ox -- dune build --root .. @order-book/all`.
