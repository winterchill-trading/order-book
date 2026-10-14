(lang dune 3.17)

(name order-book)

(generate_opam_files true)

(license MIT)

(authors "WinterChill AI")

(maintainers "hello@winterchill.xyz")

(source
 (github winterchill-trading/order-book))

(homepage "https://github.com/winterchill-trading/order-book")

(bug_reports "https://github.com/winterchill-trading/order-book/issues")

(documentation "https://github.com/winterchill-trading/order-book#readme")

(package
 (name order-book)
 (synopsis "Price-time priority limit order book with matching, for OxCaml")
 (description
  "Order_book is one instrument's limit order book: GTC, IOC and post-only (ALO) limit orders, slippage-bounded market orders, O(1) cancel, L2 snapshots and a choice of three self-trade prevention policies. Orders match best price first and oldest first within a price, and fills execute at the maker's price. The book is deterministic and does no I/O: the caller supplies the time and the trade ids. Prices and sizes are exact fixed-point decimals. The matching loop keeps its temporaries on the stack, and the best-price queries return or_null values checked with [@@zero_alloc]. Requires the OxCaml compiler.")
 (tags
  (order-book matching-engine exchange trading oxcaml))
 (depends
  oxcaml
  (ocaml
   (and
    (>= 5.2.0)
    (< 5.3~)))
  dune
  (core
   (and
    (>= v0.18~preview.130.106+341)
    (< v0.19~)))
  (ppx_jane
   (and
    (>= v0.18~preview.130.106+341)
    (< v0.19~)))
  fixed-decimal
  exchange-core
  (core_bench
   (and
    :with-test
    (>= v0.18~preview.130.106+341)
    (< v0.19~)))
  (core_unix
   (and
    :with-test
    (>= v0.18~preview.130.106+341)
    (< v0.19~)))
  (odoc :with-doc)))
