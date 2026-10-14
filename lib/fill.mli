(** A single match between an incoming (taker) order and a resting (maker) order. *)

open! Core

type t =
  { tid : Exchange_core.Trade_id.t (** from the caller's [next_tid] *)
  ; symbol : Exchange_core.Symbol.t
  ; px : Exchange_core.Price.t (** always the maker's price *)
  ; sz : Exchange_core.Size.t (** strictly positive *)
  ; taker_side : Exchange_core.Side.t
  ; taker_oid : Exchange_core.Order_id.t
  ; maker_oid : Exchange_core.Order_id.t
  ; taker : Exchange_core.Account.t
  ; maker : Exchange_core.Account.t
  ; taker_cloid : Exchange_core.Client_order_id.t option
  ; maker_cloid : Exchange_core.Client_order_id.t option
  ; time : int (** the taker's time, as given to the book *)
  }
[@@deriving sexp_of, compare, equal]

(** The opposite of [taker_side]. *)
val maker_side : t -> Exchange_core.Side.t
