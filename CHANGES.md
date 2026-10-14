# Changes

All notable changes to this library are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) (before 1.0.0, a minor version may break the API).

## Unreleased

Nothing yet.

## 0.1.0 (not yet tagged)

First release.

### Added

- `Order_book`: one instrument's price-time priority book. GTC, IOC and ALO (post-only)
  limit orders, market orders bounded by a slippage in basis points, cancel, find, best
  bid, best ask and mid, L2 snapshots, iteration in priority order and an invariant check.
- Self-trade prevention per book (`Order_book.Stp`): `Cancel_taker` (default),
  `Expire_maker` and `Cancel_both`; removed own orders are returned in
  `Result.expired_makers`.
- `Order_book.Fill`: a match with trade id, price, size, both order ids, accounts and
  client order ids.
- `best_bid_or_null`, `best_ask_or_null` and `mid_or_null`, returning `Price.t or_null`
  and checked with `[@@zero_alloc]`.
- O(1) cancel: each level is an intrusive linked list and the id index points at the node.
- `examples/quickstart.ml`, run by `dune test`.

### Fixed

- `l2` with a negative `n_levels` raised `Failure "Sequence.take"`; it now
  returns two empty lists, like `n_levels:0`.
