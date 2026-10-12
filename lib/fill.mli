(** A single match between an incoming (taker) order and a resting (maker) order. *)

open! Core
open! Exchange_core

type t =
  { tid : Trade_id.t (** unique across the exchange *)
  ; symbol : Symbol.t
  ; px : Price.t (** always the maker's price *)
  ; sz : Size.t (** strictly positive *)
  ; taker_side : Side.t
  ; taker_oid : Order_id.t
  ; maker_oid : Order_id.t
  ; taker : Account.t
  ; maker : Account.t
  ; taker_cloid : Client_order_id.t option
  ; maker_cloid : Client_order_id.t option
  ; time : int (** nanoseconds, from the caller-supplied clock *)
  }
[@@deriving sexp_of, compare, equal]

val maker_side : t -> Side.t
