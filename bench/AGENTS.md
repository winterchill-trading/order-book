# AGENTS.md (bench/)

core_bench of the book on a 1000-level book (500 bids, 500 asks, one maker per level):
submit and cancel on an existing and on a new level, a one-fill IOC match, and a 10-level
sweep followed by a re-add.

- Numbers in the README come from an Apple M-series laptop with `-quota 3`, best of two runs.
  Quote the machine and the profile with any number you copy.
- Benchmarks are not tests. Do not turn a benchmark figure into a pinned threshold.
- Run it with the `@order-book/all` alias above; the benchmark is built by it.
