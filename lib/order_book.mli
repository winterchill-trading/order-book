(** A single instrument's limit order book with price-time priority.

    Each side maps prices to levels, and a level holds its resting orders in arrival
    order. Incoming orders match against the opposite side best price first and, within a
    price, oldest first. Fills always execute at the maker's price.

    Self-trade prevention is a per-book policy ({!Stp.t}), applied when the next maker in
    priority belongs to the taker's own account. Fills made before reaching the own order
    always stand.

    The book is mutable, deterministic and does no I/O. The caller supplies the time of
    each order and a function returning fresh trade ids, and performs any margin or
    account checks before submitting.

    Prices, sizes and identifiers are the types of [exchange-core]; prices and sizes are
    fixed-point decimals counting units of [10^-8].

    {2 Example}

    {[
      open Exchange_core

      let book = Order_book.create (Symbol.of_string "BTC")
      let tid = ref 0

      let next_tid () =
        incr tid;
        Trade_id.of_int !tid
      ;;

      let limit ~oid ~owner ~side ~px ~sz =
        Order_book.add_limit
          book
          ~oid:(Order_id.of_int oid)
          ~owner:(Account.of_string owner)
          ~side
          ~px:(Price.of_string px)
          ~sz:(Size.of_string sz)
          ~tif:Gtc
          ~time:oid
          ~next_tid
          ()
      ;;

      (* Two asks rest; a buy for 1.5 at 102 then takes the 101 ask and half of the 102
         ask: [result.fills] holds two fills and [result.status] is [Filled]. *)
      let _ : Order_book.Result.t = limit ~oid:1 ~owner:"m" ~side:Sell ~px:"101" ~sz:"1"
      let _ : Order_book.Result.t = limit ~oid:2 ~owner:"m" ~side:Sell ~px:"102" ~sz:"2"
      let result = limit ~oid:3 ~owner:"t" ~side:Buy ~px:"102" ~sz:"1.5"
    ]}

    [examples/quickstart.ml] in the source repository is a complete program along these
    lines, run by [dune test]. *)

open! Core
module Fill = Fill

(** An order resting on the book. Only [remaining] changes while it rests. *)
module Resting_order : sig
  type t = private
    { oid : Exchange_core.Order_id.t
    ; owner : Exchange_core.Account.t
    ; side : Exchange_core.Side.t
    ; px : Exchange_core.Price.t
    ; mutable remaining : Exchange_core.Size.t (** unfilled size, always positive *)
    ; orig_sz : Exchange_core.Size.t (** size when submitted *)
    ; timestamp : int (** nanoseconds at which the order was accepted *)
    ; reduce_only : bool (** stored for the caller; the book does not enforce it *)
    ; cloid : Exchange_core.Client_order_id.t option
    }
  [@@deriving sexp_of]
end

(** Why the remainder of an order was cancelled. *)
module Cancel_reason : sig
  type t =
    | Ioc_unfilled (** IOC or market remainder after sweeping the book *)
    | Self_trade (** the next maker belonged to the taker's account *)
  [@@deriving sexp_of, compare, equal]
end

(** Self-trade prevention policy of a book. *)
module Stp : sig
  type t =
    | Cancel_taker
    (** matching stops, the taker's remainder is cancelled with [Cancelled Self_trade] and
        the resting order stays (the default) *)
    | Expire_maker
    (** the resting own order is removed and reported in [Result.expired_makers]; the
        taker keeps matching behind it (Hyperliquid) *)
    | Cancel_both
    (** the resting own order is removed and reported, and the taker's remainder is
        cancelled with [Cancelled Self_trade] *)
  [@@deriving sexp_of, compare, equal, enumerate]

  (** [Cancel_taker]. *)
  val default : t
end

(** What happened to the unfilled part of a submitted order. *)
module Status : sig
  type t =
    | Resting (** the remainder rests on the book *)
    | Filled (** the whole size was matched *)
    | Cancelled of Cancel_reason.t (** the remainder was cancelled *)
    | Would_cross (** ALO order rejected because it would have taken liquidity *)
  [@@deriving sexp_of, compare, equal]
end

(** Outcome of {!add_limit} or {!market}. [filled + remaining] is the submitted size. *)
module Result : sig
  type t =
    { fills : Fill.t list (** in execution order *)
    ; status : Status.t
    ; filled : Exchange_core.Size.t
    ; remaining : Exchange_core.Size.t
    (** unfilled size: resting, cancelled or rejected *)
    ; expired_makers : Resting_order.t list
    (** own resting orders removed by self-trade prevention ([Expire_maker] or
        [Cancel_both]), in the order they were reached; already off the book. Always empty
        under [Cancel_taker]. *)
    }
  [@@deriving sexp_of]
end

(** A mutable order book for one instrument. *)
type t [@@deriving sexp_of]

(** An empty book for [symbol]. [stp] defaults to [Stp.default] ([Cancel_taker]). *)
val create : ?stp:Stp.t -> Exchange_core.Symbol.t -> t

(** The instrument given to {!create}; copied into every fill. *)
val symbol : t -> Exchange_core.Symbol.t

(** The self-trade prevention policy given to {!create}. *)
val stp : t -> Stp.t

(** Submits a limit order. [Gtc] rests any remainder, [Ioc] cancels it, [Alo] is rejected
    with [Would_cross] if it would match immediately and otherwise rests in full.

    @param time
      the order's time, stored in the resting order and copied into its fills; the book
      never reads a clock
    @param next_tid called once per fill, in execution order
    @param reduce_only
      stored on the resting order (default [false]); not enforced here

      Raises (with [raise_s]) if [sz] or [px] is not positive or [oid] is already on the
      book; the book is unchanged in that case. *)
val add_limit
  :  t
  -> oid:Exchange_core.Order_id.t
  -> owner:Exchange_core.Account.t
  -> side:Exchange_core.Side.t
  -> px:Exchange_core.Price.t
  -> sz:Exchange_core.Size.t
  -> tif:Exchange_core.Tif.t
  -> ?reduce_only:bool
  -> ?cloid:Exchange_core.Client_order_id.t
  -> time:int
  -> next_tid:(unit -> Exchange_core.Trade_id.t)
  -> unit
  -> Result.t

(** The worst acceptable price for a market order: the best opposite price moved against
    the taker by [slippage_bps] basis points (truncated toward zero, and never below zero
    for a sell). [None] if the opposite side is empty. *)
val market_limit_px
  :  t
  -> side:Exchange_core.Side.t
  -> slippage_bps:int
  -> Exchange_core.Price.t option

(** Sweeps the opposite side up to [market_limit_px], like an IOC order at that price; a
    market order never rests. With an empty opposite side nothing fills and the status is
    [Cancelled Ioc_unfilled].

    Raises (with [raise_s]) if [sz] is not positive or [oid] is already on the book. *)
val market
  :  t
  -> oid:Exchange_core.Order_id.t
  -> owner:Exchange_core.Account.t
  -> side:Exchange_core.Side.t
  -> sz:Exchange_core.Size.t
  -> slippage_bps:int
  -> ?reduce_only:bool
  -> ?cloid:Exchange_core.Client_order_id.t
  -> time:int
  -> next_tid:(unit -> Exchange_core.Trade_id.t)
  -> unit
  -> Result.t

(** Removes a resting order in O(1), returning it, or [None] if it is not on the book. *)
val cancel : t -> Exchange_core.Order_id.t -> Resting_order.t option

(** The resting order with this id, if it is on the book. *)
val find : t -> Exchange_core.Order_id.t -> Resting_order.t option

(** Highest bid price, if any. *)
val best_bid : t -> Exchange_core.Price.t option

(** Lowest ask price, if any. *)
val best_ask : t -> Exchange_core.Price.t option

(** Midpoint of the best bid and ask, when both exist (rounded toward zero). *)
val mid : t -> Exchange_core.Price.t option

(** {2 Queries without allocation}

    [best_bid], [best_ask] and [mid] returning [Null] where those return [None]. They use
    OxCaml's [or_null] type, so the result is never boxed, and the compiler checks that
    they do not allocate. *)

val best_bid_or_null : t -> Exchange_core.Price.t or_null [@@zero_alloc]
val best_ask_or_null : t -> Exchange_core.Price.t or_null [@@zero_alloc]
val mid_or_null : t -> Exchange_core.Price.t or_null [@@zero_alloc]

(** {2 Snapshots and iteration} *)

(** Aggregated levels, best first, at most [n_levels] per side: [(bids, asks)]. A
    non-positive [n_levels] gives two empty lists. *)
val l2
  :  t
  -> n_levels:int
  -> Exchange_core.L2.Level.t list * Exchange_core.L2.Level.t list

(** Visits every resting order: bids from best to worst, then asks from best to worst, in
    time priority within a level. [f] is a local closure and must not modify the book. *)
val iter : t -> f:(Resting_order.t -> unit) @ local -> unit

(** Every resting order, in the order {!iter} visits them. *)
val orders : t -> Resting_order.t list

(** Number of resting orders on both sides. *)
val length : t -> int

val is_empty : t -> bool

(** Checks the internal invariants: the book is not crossed, levels are non-empty and
    their totals and links agree with their orders, the id index matches the levels, and
    the cached best levels and [_or_null] queries agree with the maps. Linear in the size
    of the book; meant for tests. Raises (with [raise_s]) naming the first violated
    invariant. *)
val invariant : t -> unit
