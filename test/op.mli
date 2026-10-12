(** Random order book operations for property tests. *)

open! Core
open! Exchange_core

type t =
  | Limit of
      { owner : int
      ; side : Side.t
      ; px : int (** whole price units *)
      ; sz : int (** whole size units *)
      ; tif : Tif.t
      }
  | Market of
      { owner : int
      ; side : Side.t
      ; sz : int
      }
  | Cancel of int (** an index into the resting orders, or an oid, per test *)
[@@deriving sexp_of]

(** Owners 1-4, prices 95-105, sizes 1-5 (limit) or 1-8 (market). *)
val gen : t Quickcheck.Generator.t
