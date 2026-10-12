# order-book

Price-time priority limit order book with matching, for one instrument.

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core).
Prices, sizes, symbols, order and trade ids, accounts and client order ids use the
venue-neutral types from
[exchange-core](https://github.com/winterchill-trading/exchange-core); prices and sizes
are fixed-point decimals from
[fixed-decimal](https://github.com/winterchill-trading/fixed-decimal). Nothing here is
specific to one venue.

The book is pure and mutable: it does no I/O and performs no margin or account checks.
An exchange simulator or engine drives it and settles the fills it returns.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action
opam pin add exchange-core https://github.com/winterchill-trading/exchange-core.git --no-action
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains `exchange-core` and `fixed-decimal`, dune uses
the sibling sources and the pins are not needed.

CI installs the pinned siblings and the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.

## API

The library `order-book` exposes one module, `Order_book`:

| Module | Description |
| --- | --- |
| `Order_book` | One instrument's book: price-time priority, GTC/IOC/ALO limit orders, slippage-bounded market orders, cancel, L2 snapshot, iteration, invariant check |
| `Order_book.Fill` | A taker/maker match: trade id, symbol, price, size, both order ids, accounts and client order ids |
| `Order_book.Resting_order` | An order on the book, with its mutable remaining size |
| `Order_book.Status`, `Order_book.Cancel_reason`, `Order_book.Result` | Outcome of a submission: fills in execution order, filled and remaining size |

## Design notes

- **Determinism.** Time is an `int` supplied by the caller; trade ids
  (`Exchange_core.Trade_id.t`) come from a caller-supplied `next_tid` function called
  once per fill. The book never reads the
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

### Unboxed fields and `or_null` (analysis)

Candidates on the hot path, not yet changed. Prices, sizes and ids are already tagged
`int`s at run time, so most gains come from removing `Some` boxes and pointer hops:

| Record / field | Today | Candidate | Gain |
| --- | --- | --- | --- |
| `t.top_bid`, `t.top_ask` | `Level.t option` | `Level.t or_null` | no `Some` allocation when the best level changes, one load less per matching step |
| `Fill.t.taker_cloid`, `maker_cloid` | `Client_order_id.t option` | `or_null` | 2 words less per fill when a client id is set |
| `Resting_order.t.cloid` | `Client_order_id.t option` | `or_null` | 2 words less per resting order with a client id |
| `best_bid`, `best_ask`, `mid` results | `Price.t option` | `Price.t or_null` | no allocation at all; changes the public interface |
| `Level.t.orders` | pointer to a `Queue.t` record, which points to its array | queue fields inlined into `Level.t` (own ring buffer, or an unboxed record field) | one pointer hop per maker visited |
| `Fixed_decimal.S.t` (`Price`, `Size`) | abstract type, layout `value` | declared `immediate` | lets local values cross modes, so `exclave_` query variants become usable (see Allocation), and allows `int`-like unboxed storage |

`Fill.t` itself has to stay a heap record: fills are returned to the caller in a list.
The per-call `taker` and `swept` records are already stack-allocated.

## Tests

`dune test` runs expect tests (priority, partial fills, TIF semantics, self-trade,
market orders, cancel, L2 shape) and `Base_quickcheck` properties over random operation
sequences: books never cross, taker and maker filled sizes agree, remaining sizes stay
positive and cancelling everything empties the book. A stress test sweeps 200k makers
with one taker.

`test/test_bisim.ml` checks the book by bisimulation against `test/naive_book.ml`, a
reference matcher that keeps resting orders in one list and re-sorts it on every step:
after each random operation both must report the same fills, status, remainder, cancel
result and full L2. A second property decodes random byte strings into operations
(`Op.of_bytes`) as a fuzz input. Hand-picked edge cases (self-trade mid-sweep, ALO at
the touch, market orders on an empty book or beyond the slippage limit, cancelling a
filled order, FIFO after a partial fill) are pinned with `~examples`, so they run on
every test run. `test/test_alloc.ml` prints minor words per operation.

## Benchmarks

`bench/main.ml` runs [core_bench](https://github.com/janestreet/core_bench) on a
1000-level book (500 bids, 500 asks, one maker per level):

```sh
dune exec ./bench/main.exe -- -quota 2 -ascii
```

Each case leaves the book as it found it, so some cases measure a pair of operations.
Apple M3 Max, default (non `-O3`) build:

| Case | Time/run | Minor words/run |
| --- | ---: | ---: |
| submit + cancel, existing level | 222 ns | 46 |
| submit + cancel, new level | 332 ns | 187 |
| match 1 fill (IOC against a deep maker) | 77 ns | 32 |
| sweep 10 levels, then re-add the 10 makers | 3.4 us | 1820 |
| `l2 ~n_levels:10` | 211 ns | 656 |
| `best_bid` | 9 ns | 8 |

These are the numbers before the best-level cache described under Allocation; with it,
`best_bid` takes 4 ns and 5 words and a single-fill match 27 words.

### Release build and `-O3`

The ox compiler is flambda2. Three builds of the benchmark, each run twice with
`-quota 3` (best of the two runs, same machine, after the best-level cache):

```sh
dune build --profile release ./bench/main.exe                        # release
OCAMLPARAM='_,O3=1' dune build --profile release ./bench/main.exe    # -O3 everywhere
```

| Case | dev | release | release, `-O3` |
| --- | ---: | ---: | ---: |
| submit + cancel, existing level | 223 ns | 195 ns | 158 ns |
| submit + cancel, new level | 329 ns | 321 ns | 288 ns |
| match 1 fill (IOC) | 74 ns, 27 w | 66 ns, 27 w | 37 ns, 22 w |
| sweep 10 levels, then re-add | 3.35 us | 3.29 us | 2.74 us |
| `l2 ~n_levels:10` | 209 ns | 208 ns | 198 ns |
| `best_bid` | 3.6 ns, 5 w | 3.4 ns, 5 w | 2.5 ns, 3 w |

`-O3` roughly halves the cost of a single fill and cuts its allocation, because
`Price`, `Size` and `Account` comparisons from `exchange-core` and `fixed-decimal` get
inlined into the matching loop. The gain needs `-O3` on those libraries too:
compiling only this repository with `-O3` (an `env` stanza for the release profile)
brought the single fill from 66 ns to 62 ns. `OCAMLPARAM` covers every library built
from source in the workspace, but not opam-installed ones (Core), so binaries that want
the speed-up should set it when building the whole stack.

### Allocation

`test/test_alloc.ml` prints minor-heap words per operation on the same book, so a change
in allocation shows up as an expect-test diff. Caching the best level of each side (instead
of calling `Map.max_elt`/`Map.min_elt`, which allocate a `Some (key, data)`) changed:

| Operation | Before | After |
| --- | ---: | ---: |
| `best_bid` / `best_ask` | 5 | 2 |
| `mid` | 12 | 2 |
| `find` | 2 | 2 |
| `l2 ~n_levels:10` | 653 | 653 |
| match 1 fill (IOC) | 31 | 26 |
| submit + cancel | 43 | 38 |

The remaining 2 words of `best_bid` are the `Some`. A `local_` variant returning
`Price.t option @ local` (built with `exclave_`) would avoid it, but `Price.t` is abstract
and not declared immediate, so the price inside a local option is itself local and cannot
be passed to `Price.to_units`, `Price.equal` or any other function taking a global
argument. The variant was dropped; it becomes useful once `Fixed_decimal.S.t` is declared
`immediate`. `l2` allocates its result lists and the `Sequence` machinery; it is not on
the matching path.
