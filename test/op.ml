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

let limit ?(tif = Tif.Gtc) owner side px sz = Limit { owner; side; px; sz; tif }

let examples =
  [ (* Self-trade in the middle of a sweep: one fill, then the taker's own ask stops it. *)
    [ limit 1 Sell 100 2; limit 2 Sell 101 2; limit 2 Buy 102 5 ]
  ; (* ALO at the touch is rejected; one tick away it rests. *)
    [ limit 1 Sell 100 1; limit ~tif:Alo 2 Buy 100 1; limit ~tif:Alo 2 Buy 99 1 ]
  ; (* Market on an empty book, then a market order limited by the 3% slippage. *)
    [ Market { owner = 1; side = Buy; sz = 3 }
    ; limit 1 Sell 100 1
    ; limit 1 Sell 104 1
    ; Market { owner = 2; side = Buy; sz = 5 }
    ]
  ; (* Partial fill of a maker, then cancelling it twice. *)
    [ limit 1 Sell 100 5; limit ~tif:Ioc 2 Buy 100 2; Cancel 0; Cancel 0 ]
  ; (* FIFO within a level survives a partial fill of the first maker. *)
    [ limit 1 Sell 100 3; limit 2 Sell 100 3; limit 3 Buy 100 4; limit 4 Buy 100 3 ]
  ; (* An IOC empties the best level exactly, then the other side rests at that price. *)
    [ limit 1 Buy 99 2; limit 1 Buy 98 2; limit ~tif:Ioc 2 Sell 99 2; limit 3 Sell 99 1 ]
  ]
;;
