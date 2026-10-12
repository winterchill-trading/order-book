open! Core
open! Exchange_core

type t =
  { tid : Trade_id.t
  ; symbol : Symbol.t
  ; px : Price.t
  ; sz : Size.t
  ; taker_side : Side.t
  ; taker_oid : Order_id.t
  ; maker_oid : Order_id.t
  ; taker : Account.t
  ; maker : Account.t
  ; taker_cloid : Client_order_id.t option
  ; maker_cloid : Client_order_id.t option
  ; time : int
  }
[@@deriving sexp_of, compare, equal]

let maker_side t = Side.flip t.taker_side
