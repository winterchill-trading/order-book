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

(** Hand-picked sequences for edge cases (self-trade mid-sweep, ALO at the touch, market
    orders on an empty book and beyond the slippage limit, cancelling a filled order, FIFO
    after a partial fill, emptying the best level). Passed to properties as [~examples] so
    they run on every test run. *)
val examples : t list list

(** Decodes a byte string into operations, three bytes per operation (trailing bytes are
    ignored). Every byte string decodes, so random strings make a fuzz input. *)
val of_bytes : string -> t list
