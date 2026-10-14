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

## Install

The library needs the [OxCaml](https://oxcaml.org) compiler and the Jane Street
`v0.18~preview` packages from the OxCaml opam repository. Its two dependencies,
`fixed-decimal` and `exchange-core`, are not on opam yet, so pin them from GitHub:

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action
opam pin add exchange-core https://github.com/winterchill-trading/exchange-core.git --no-action
opam pin add order-book https://github.com/winterchill-trading/order-book.git
```

From a checkout:

```sh
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains `exchange-core` and `fixed-decimal`, dune uses
the sibling sources and the pins are not needed.

## API

The library `order-book` exposes one module, `Order_book`:

| Module | Description |
| --- | --- |
| `Order_book` | One instrument's book: price-time priority, GTC/IOC/ALO limit orders, slippage-bounded market orders, cancel, L2 snapshot, iteration, invariant check |
| `Order_book.Fill` | A taker/maker match: trade id, symbol, price, size, both order ids, accounts and client order ids |
| `Order_book.Resting_order` | An order on the book, with its mutable remaining size |
| `Order_book.Stp` | Self-trade prevention policy of a book: `Cancel_taker` (default), `Expire_maker`, `Cancel_both` |
| `Order_book.Status`, `Order_book.Cancel_reason`, `Order_book.Result` | Outcome of a submission: fills in execution order, filled and remaining size, own makers expired by self-trade prevention |

## Design notes

- **Determinism.** Time is an `int` supplied by the caller; trade ids
  (`Exchange_core.Trade_id.t`) come from a caller-supplied `next_tid` function called
  once per fill. The book never reads the
  wall clock.
- **Matching.** Each side is a `Map` from price to a level, and a level is a FIFO of
  resting orders. Incoming orders match
  against the opposite side best price first and, within a price, oldest first. Fills
  execute at the maker's price. Market orders are IOC orders priced `slippage_bps`
  through the best opposite price.
- **Time in force.** `Gtc` rests any remainder, `Ioc` cancels it, `Alo` is rejected with
  `Would_cross` if it would take liquidity and otherwise rests in full.
- **Self-trade prevention.** A per-book policy, chosen with
  `Order_book.create ?stp`, applied when the next maker in priority belongs to the taker.
  Earlier fills always stand.

  | `Stp.t` | Resting own order | Taker | Used by |
  | --- | --- | --- | --- |
  | `Cancel_taker` (default) | stays on the book | remainder cancelled, `Cancelled Self_trade` | Binance and Bybit simulators (unchanged behaviour) |
  | `Expire_maker` | removed, listed in `Result.expired_makers` | keeps matching behind it; may fill, rest or be IOC-cancelled as usual | Hyperliquid |
  | `Cancel_both` | removed, listed in `Result.expired_makers` | remainder cancelled, `Cancelled Self_trade` | |

  `Result.expired_makers` holds the removed orders in the order they were reached, so an
  engine can release their margin and report them (on Hyperliquid, `selfTradeCanceled` in
  `orderUpdates`). Expired orders produce no fill and no fee. It is always empty under
  `Cancel_taker`.
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
- `Order_book.iter` takes its callback `@ local`, and Base's `Map` iterators
  accept local closures, so the wrappers stay on the stack.

### Unboxed fields and `or_null` (analysis)

Candidates on the hot path, not yet changed. Prices, sizes and ids are already tagged
`int`s at run time, so most gains come from removing `Some` boxes and pointer hops:

| Record / field | Today | Candidate | Gain |
| --- | --- | --- | --- |
| `t.top_bid`, `t.top_ask` | `Level.t option` | `Level.t or_null` | no `Some` allocation when the best level changes, one load less per matching step |
| `Fill.t.taker_cloid`, `maker_cloid` | `Client_order_id.t option` | `or_null` | 2 words less per fill when a client id is set |
| `Resting_order.t.cloid` | `Client_order_id.t option` | `or_null` | 2 words less per resting order with a client id |
| `best_bid`, `best_ask`, `mid` results | `Price.t option` | `Price.t or_null` | done, as `best_bid_or_null`, `best_ask_or_null`, `mid_or_null` beside the option versions: 0 words |
| `Level.t.orders` | pointer to a `Queue.t` record, which points to its array | done: the level holds the head and tail of an intrusive list of nodes | O(1) cancel (see below) |
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
filled order, FIFO after a partial fill, consecutive own makers) are pinned with
`~examples`, so they run on every test run. The reference matcher implements each
self-trade policy independently, and both properties run under all three policies. `test/test_alloc.ml` prints minor words per operation.

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

### Self-trade policy

Adding `Stp.t` and `Result.expired_makers` (three runs each of the bench at the previous
commit and with the change, `-quota 2`, same machine, dev build):

| Case | Before | After |
| --- | ---: | ---: |
| submit + cancel, existing level | 143 to 144 ns, 40 w | 147 ns, 40 w |
| submit + cancel, 1000-order level | 145 ns, 40 w | 154 to 155 ns, 40 w |
| submit + cancel, new level | 278 to 280 ns, 175 w | 282 to 286 ns, 175 w |
| match 1 fill (IOC) | 69 to 71 ns, 27 w | 71 to 72 ns, 28 w |
| sweep 10 levels, then re-add | 3.19 to 3.20 us, 1762 w | 3.22 to 3.34 us, 1773 w |

Times are within noise of each other. The one extra word per submission is the new
`Result.t` field (the empty list is an immediate). `test/test_alloc.ml` pins a single
fill at 27 words (was 26) and resting an own ask then expiring it with an own IOC at 58
words. Numbers are arm64; CI runs on amd64.

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

### `or_null` queries and O(1) cancel

`best_bid_or_null`, `best_ask_or_null` and `mid_or_null` return `Price.t or_null`
(`Null` where the option versions return `None`) and allocate nothing; all three are
`[@@zero_alloc]` in the `.mli` (`mid_or_null` since `fixed-decimal` annotates
`Price.of_units`), and `test/test_alloc.ml` also pins them at 0 words. `invariant` checks that each agrees with its option version, so every property
test compares them.

A level is an intrusive doubly linked list of nodes (`prev`/`next` are `node or_null`, so
an end of the list is an immediate rather than a `Some` box), and the order index maps
each oid to its node, which also points to its level. `cancel` unlinks the node in O(1)
with no map lookup; it used to run `Queue.filter_inplace` over the whole level after a
`Map.find`. The bisimulation test against `test/naive_book.ml` and a head/middle/tail
cancel expect test cover the change, and `invariant` now checks the links.

Minor words per call, from `test/test_alloc.ml` (exact) and core_bench (which adds 3
words of harness per case):

| Operation | Before | After |
| --- | ---: | ---: |
| `best_bid` / `best_ask` / `mid` | 2 | 2 (option), 0 (`or_null`) |
| submit + cancel, existing level | 38 | 37 |
| submit + cancel behind 1000 orders (bench) | 556 minor and 1538 major | 40 |
| submit + cancel, new level (bench) | 183 | 175 |
| match 1 fill (IOC) | 26 | 26 |

Time per call for the cancel behind 1000 orders, best of two runs per build on an Apple
M3 Max: 24.8 us to 0.26 us at best, and 25 to 161 us before against 0.26 to 1.4 us
after in every dev, release and `-O3` run. The other cases measured within noise of the
earlier tables: the machine was shared with heavy parallel builds during the run, so
sub-microsecond timings from it are not reported. CI runs on amd64; these numbers are
arm64.

