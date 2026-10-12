open! Core
open! Exchange_core

type t =
  | Limit of
      { owner : int
      ; side : Side.t
      ; px : int
      ; sz : int
      ; tif : Tif.t
      }
  | Market of
      { owner : int
      ; side : Side.t
      ; sz : int
      }
  | Cancel of int
[@@deriving sexp_of]

let gen =
  let open Quickcheck.Generator.Let_syntax in
  let owner = Int.gen_incl 1 4 in
  let side = Quickcheck.Generator.of_list Side.all in
  Quickcheck.Generator.weighted_union
    [ ( 6.
      , let%map owner
        and side
        and px = Int.gen_incl 95 105
        and sz = Int.gen_incl 1 5
        and tif = Quickcheck.Generator.of_list Tif.all in
        Limit { owner; side; px; sz; tif } )
    ; ( 1.
      , let%map owner
        and side
        and sz = Int.gen_incl 1 8 in
        Market { owner; side; sz } )
    ; (2., Int.gen_incl 0 1000 >>| fun i -> Cancel i)
    ]
;;
