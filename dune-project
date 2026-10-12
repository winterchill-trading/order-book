(lang dune 3.17)

(name order-book)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/order-book))

(package
 (name order-book)
 (synopsis "Price-time priority limit order book with matching (OxCaml)")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  fixed-decimal
  exchange-core
  ppx_jane))
