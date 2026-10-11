# order-book

Price-time priority limit order book with matching, for one coin.

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core).
Prices, sizes, coins, order ids and addresses use the types from
[hl-protocol](https://github.com/winterchill-trading/hl-protocol), which are
fixed-point decimals from
[fixed-decimal](https://github.com/winterchill-trading/fixed-decimal).

The book is pure and mutable: it does no I/O and performs no margin or account checks.
An exchange simulator or engine drives it and settles the fills it returns.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action
opam pin add hl-protocol https://github.com/winterchill-trading/hl-protocol.git --no-action
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains `hl-protocol` and `fixed-decimal`, dune uses
the sibling sources and the pins are not needed.

## API

The library `order-book` exposes one module, `Order_book`:

| Module | Description |
| --- | --- |
| `Order_book` | One coin's book: price-time priority, GTC/IOC/ALO limit orders, slippage-bounded market orders, cancel, L2 snapshot, iteration, invariant check |
| `Order_book.Fill` | A taker/maker match: trade id, price, size, both oids, accounts and cloids; conversion to the public `Trade.t` |
| `Order_book.Resting_order` | An order on the book, with its mutable remaining size |
| `Order_book.Status`, `Order_book.Cancel_reason`, `Order_book.Result` | Outcome of a submission: fills in execution order, filled and remaining size |

## Design notes

- **Determinism.** Time is an `int` supplied by the caller; trade ids come from a
  caller-supplied `next_tid` function called once per fill. The book never reads the
  wall clock.
- **Matching.** Each side is a `Map` from price to a FIFO `Queue`. Incoming orders match
  against the opposite side best price first and, within a price, oldest first. Fills
  execute at the maker's price. Market orders are IOC orders priced `slippage_bps`
  through the best opposite price.
- **Time in force.** `Gtc` rests any remainder, `Ioc` cancels it, `Alo` is rejected with
  `Would_cross` if it would take liquidity and otherwise rests in full.
- **Self-trade prevention.** When the next maker in priority belongs to the taker,
  matching stops and the taker's remainder is cancelled; earlier fills stand and the
  resting order is untouched.
- **Fixed point.** Prices and sizes count units of `10^-8` in an `int`; the market order
  limit price is computed with `Fixed_decimal.mul_units`, which does not overflow and
  truncates toward zero.

### OxCaml

The matching loop (`Order_book.sweep`) uses OxCaml modes to avoid heap allocation of
per-order temporaries:

- the taker's context record is stack-allocated with `let local_` and passed as a
  `local_` argument; its non-immediate fields are `global_` so they can be copied into
  heap-allocated fills;
- the loop's result is returned in the caller's region with `exclave_`, as a record with
  `global_` fields (a local tuple would make its components local, and they could not
  escape into the result);
- `Order_book.iter` takes its callback `@ local`, and Base's `Map` and `Queue` iterators
  accept local closures, so the wrappers stay on the stack.

## Tests

`dune test` runs expect tests (priority, partial fills, TIF semantics, self-trade,
market orders, cancel, L2 shape) and `Base_quickcheck` properties over random operation
sequences: books never cross, taker and maker filled sizes agree, remaining sizes stay
positive and cancelling everything empties the book. A stress test sweeps 200k makers
with one taker.
