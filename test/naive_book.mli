(** A deliberately simple reference matcher: resting orders in one list, re-sorted by
    price-time priority on every match. Used to check [Order_book] by bisimulation. *)

open! Core
open! Exchange_core

type t

(** [stp] defaults to [Order_book.Stp.default]. *)
val create : ?stp:Order_book.Stp.t -> unit -> t

(** A fill as the model sees it: maker oid, price, size. *)
module Fill : sig
  type t =
    { maker_oid : Order_id.t
    ; px : Price.t
    ; sz : Size.t
    }
  [@@deriving sexp_of, compare, equal]
end

module Outcome : sig
  type t =
    { fills : Fill.t list
    ; status : Order_book.Status.t
    ; remaining : Size.t
    ; expired : Order_id.t list (** own makers removed by self-trade prevention *)
    }
  [@@deriving sexp_of, compare, equal]
end

val add_limit
  :  t
  -> oid:Order_id.t
  -> owner:Account.t
  -> side:Side.t
  -> px:Price.t
  -> sz:Size.t
  -> tif:Tif.t
  -> Outcome.t

val market
  :  t
  -> oid:Order_id.t
  -> owner:Account.t
  -> side:Side.t
  -> sz:Size.t
  -> slippage_bps:int
  -> Outcome.t

(** Whether the order was resting. *)
val cancel : t -> Order_id.t -> bool

(** All levels, best first: [(bids, asks)]. *)
val l2 : t -> L2.Level.t list * L2.Level.t list
