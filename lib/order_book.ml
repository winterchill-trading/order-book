open! Core
open! Exchange_core
module Fill = Fill

module Resting_order = struct
  type t =
    { oid : Order_id.t
    ; owner : Account.t
    ; side : Side.t
    ; px : Price.t
    ; mutable remaining : Size.t
    ; orig_sz : Size.t
    ; timestamp : int
    ; reduce_only : bool
    ; cloid : Client_order_id.t option
    }
  [@@deriving sexp_of]
end

module Cancel_reason = struct
  type t =
    | Ioc_unfilled
    | Self_trade
  [@@deriving sexp_of, compare, equal]
end

module Stp = struct
  type t =
    | Cancel_taker
    | Expire_maker
    | Cancel_both
  [@@deriving sexp_of, compare, equal, enumerate]

  let default = Cancel_taker
end

module Status = struct
  type t =
    | Resting
    | Filled
    | Cancelled of Cancel_reason.t
    | Would_cross
  [@@deriving sexp_of, compare, equal]
end

module Result = struct
  type t =
    { fills : Fill.t list
    ; status : Status.t
    ; filled : Size.t
    ; remaining : Size.t
    ; expired_makers : Resting_order.t list
    }
  [@@deriving sexp_of]
end

(* A price level is an intrusive doubly linked FIFO of nodes, and the order index maps
   each oid to its node, so cancelling an order unlinks it in O(1) instead of filtering
   the level's queue. Links are [or_null], so an end of the list is an immediate, not a
   [Some] box. *)
module Level = struct
  type node =
    { order : Resting_order.t
    ; level : t
    ; mutable prev : node or_null
    ; mutable next : node or_null
    }

  and t =
    { px : Price.t
    ; mutable total : Size.t
    ; mutable head : node or_null
    ; mutable tail : node or_null
    ; mutable length : int
    }

  let create px = { px; total = Size.zero; head = Null; tail = Null; length = 0 }
  let is_empty t = t.length = 0

  let push_back t order =
    let node = { order; level = t; prev = t.tail; next = Null } in
    (match t.tail with
     | Null -> t.head <- This node
     | This last -> last.next <- This node);
    t.tail <- This node;
    t.length <- t.length + 1;
    node
  ;;

  let remove t node =
    (match node.prev with
     | Null -> t.head <- node.next
     | This prev -> prev.next <- node.next);
    (match node.next with
     | Null -> t.tail <- node.prev
     | This next -> next.prev <- node.prev);
    node.prev <- Null;
    node.next <- Null;
    t.length <- t.length - 1
  ;;

  (* A loop rather than recursion: a level can hold any number of orders, and a recursive
     call passing the [local_] [f] could not be a tail call. *)
  let iter t ~(f : Resting_order.t -> unit @ local) =
    let mutable cur = t.head in
    let mutable continue = true in
    while continue do
      match cur with
      | Null -> continue <- false
      | This node ->
        f node.order;
        cur <- node.next
    done
  ;;

  let to_list t =
    let acc = ref [] in
    iter t ~f:(fun o -> acc := o :: !acc);
    List.rev !acc
  ;;

  let sexp_of_t t =
    [%sexp
      { px : Price.t = t.px
      ; total : Size.t = t.total
      ; orders : Resting_order.t list = to_list t
      }]
  ;;

  let sexp_of_node node = Resting_order.sexp_of_t node.order
end

type t =
  { symbol : Symbol.t
  ; stp : Stp.t
  ; mutable bids : Level.t Price.Map.t
  ; mutable asks : Level.t Price.Map.t
  ; index : Level.node Order_id.Table.t
  ; (* The best level of each side, cached so that queries and the matching loop do not
       allocate the [(key, data) option] that [Map.max_elt] and [Map.min_elt] return.
       Updated when a better level is created or the best level is removed. *)
    mutable top_bid : Level.t option [@sexp_drop_if fun _ -> true]
  ; mutable top_ask : Level.t option [@sexp_drop_if fun _ -> true]
  }
[@@deriving sexp_of]

let create ?(stp = Stp.default) symbol =
  { symbol
  ; stp
  ; bids = Price.Map.empty
  ; asks = Price.Map.empty
  ; index = Order_id.Table.create ()
  ; top_bid = None
  ; top_ask = None
  }
;;

let symbol t = t.symbol
let stp t = t.stp

let side_levels t (side : Side.t) =
  match side with
  | Buy -> t.bids
  | Sell -> t.asks
;;

let set_side_levels t (side : Side.t) levels =
  match side with
  | Buy -> t.bids <- levels
  | Sell -> t.asks <- levels
;;

let top t (side : Side.t) =
  match side with
  | Buy -> t.top_bid
  | Sell -> t.top_ask
;;

let set_top t (side : Side.t) level =
  match side with
  | Buy -> t.top_bid <- level
  | Sell -> t.top_ask <- level
;;

(* Whether [px] is a better price than [than] for resting orders on [side]. *)
let better (side : Side.t) px ~than =
  match side with
  | Buy -> Price.( > ) px than
  | Sell -> Price.( < ) px than
;;

(* Best level of a side: highest bid, lowest ask. *)
let best_level = top
let best_bid t = Option.map t.top_bid ~f:(fun (l : Level.t) -> l.px)
let best_ask t = Option.map t.top_ask ~f:(fun (l : Level.t) -> l.px)

let mid_px (b : Level.t) (a : Level.t) =
  Price.of_units ((Price.to_units b.px + Price.to_units a.px) / 2)
;;

let mid t =
  match t.top_bid, t.top_ask with
  | Some b, Some a -> Some (mid_px b a)
  | _ -> None
;;

let best_bid_or_null t : Price.t or_null =
  match t.top_bid with
  | Some l -> This l.px
  | None -> Null
;;

let best_ask_or_null t : Price.t or_null =
  match t.top_ask with
  | Some l -> This l.px
  | None -> Null
;;

let mid_or_null t : Price.t or_null =
  match t.top_bid, t.top_ask with
  | Some b, Some a -> This (mid_px b a)
  | _ -> Null
;;

(* Whether a taker on [side] with [limit] would trade against a maker at [px]. *)
let crosses (side : Side.t) ~limit px =
  match side with
  | Buy -> Price.( <= ) px limit
  | Sell -> Price.( >= ) px limit
;;

let rest t (order : Resting_order.t) =
  let levels = side_levels t order.side in
  let level =
    match Map.find levels order.px with
    | Some level -> level
    | None ->
      let level = Level.create order.px in
      set_side_levels t order.side (Map.set levels ~key:order.px ~data:level);
      (match top t order.side with
       | Some (best : Level.t) when not (better order.side order.px ~than:best.px) -> ()
       | _ -> set_top t order.side (Some level));
      level
  in
  let node = Level.push_back level order in
  level.total <- Size.( + ) level.total order.remaining;
  Hashtbl.set t.index ~key:order.oid ~data:node
;;

let remove_level_if_empty t (side : Side.t) px (level : Level.t) =
  if Level.is_empty level
  then (
    let levels = Map.remove (side_levels t side) px in
    set_side_levels t side levels;
    match top t side with
    | Some best when phys_equal best level ->
      let next =
        match side with
        | Buy -> Map.max_elt levels
        | Sell -> Map.min_elt levels
      in
      set_top t side (Option.map next ~f:snd)
    | _ -> ())
;;

(* Removes a resting order's node from its level, the index and, if the level empties, the
   side. *)
let unlink t (node : Level.node) =
  let order = node.order in
  let level = node.level in
  Hashtbl.remove t.index order.oid;
  Level.remove level node;
  level.total <- Size.( - ) level.total order.remaining;
  remove_level_if_empty t order.side order.px level
;;

(* Per-call context of the incoming order, threaded through the matching loop.

   OxCaml: the record is allocated on the stack ([local_]) by [sweep]'s caller and passed
   down as a [local_] argument, so matching an order does not heap-allocate its context.
   Fields whose types are not immediate are marked [global_] so that reading them yields
   heap values which may be stored into the (heap-allocated) fills. *)
type taker =
  { global_ oid : Order_id.t
  ; global_ owner : Account.t
  ; side : Side.t
  ; global_ limit : Price.t
  ; global_ cloid : Client_order_id.t option
  ; time : int
  ; global_ next_tid : unit -> Trade_id.t
  }

type stop =
  | Done
  | Exhausted
  | Self_trade

(* Result of [sweep], returned on the caller's stack ([exclave_]). A local tuple would
   make its components local too, so the components could not escape into the heap
   [Result.t]; [global_] record fields avoid that. *)
type swept =
  { global_ unfilled : Size.t
  ; global_ rev_fills : Fill.t list
  ; global_ rev_expired : Resting_order.t list
  ; stop : stop
  }

(* Matches [remaining] against the opposite side until filled, out of crossing liquidity,
   or stopped by an own order (depending on the book's [Stp.t]). Returns the unfilled
   size, the fills and the expired own makers in reverse order, and why matching stopped.

   OxCaml: the recursive call is [exclave_ sweep ...], which ends this frame's region
   before the call so it stays a tail call while still returning into the caller's region
   (a plain call is rejected: the result is local, not a global return value). *)
let rec sweep t (local_ (taker : taker)) remaining fills expired =
  if Size.is_zero remaining
  then
    exclave_
    { unfilled = remaining; rev_fills = fills; rev_expired = expired; stop = Done }
  else (
    let opposite = Side.flip taker.side in
    match best_level t opposite with
    | None ->
      exclave_
      { unfilled = remaining; rev_fills = fills; rev_expired = expired; stop = Exhausted }
    | Some level when not (crosses taker.side ~limit:taker.limit level.px) ->
      exclave_
      { unfilled = remaining; rev_fills = fills; rev_expired = expired; stop = Exhausted }
    | Some level ->
      let px = level.px in
      let node =
        match level.head with
        | This node -> node
        | Null -> raise_s [%message "Order_book: empty level on the book"]
      in
      let maker = node.order in
      if Account.equal maker.owner taker.owner
      then (
        match t.stp with
        | Cancel_taker ->
          exclave_
          { unfilled = remaining
          ; rev_fills = fills
          ; rev_expired = expired
          ; stop = Self_trade
          }
        | Expire_maker ->
          unlink t node;
          exclave_ sweep t taker remaining fills (maker :: expired)
        | Cancel_both ->
          unlink t node;
          exclave_
          { unfilled = remaining
          ; rev_fills = fills
          ; rev_expired = maker :: expired
          ; stop = Self_trade
          })
      else (
        let sz = Size.min remaining maker.remaining in
        maker.remaining <- Size.( - ) maker.remaining sz;
        level.total <- Size.( - ) level.total sz;
        if Size.is_zero maker.remaining
        then (
          Level.remove level node;
          Hashtbl.remove t.index maker.oid;
          remove_level_if_empty t opposite px level);
        let fill : Fill.t =
          { tid = taker.next_tid ()
          ; symbol = t.symbol
          ; px
          ; sz
          ; taker_side = taker.side
          ; taker_oid = taker.oid
          ; maker_oid = maker.oid
          ; taker = taker.owner
          ; maker = maker.owner
          ; taker_cloid = taker.cloid
          ; maker_cloid = maker.cloid
          ; time = taker.time
          }
        in
        exclave_ sweep t taker (Size.( - ) remaining sz) (fill :: fills) expired))
;;

let check_new_order t ~oid ~sz =
  if not (Size.is_positive sz)
  then raise_s [%message "Order_book: size must be positive" (sz : Size.t)];
  if Hashtbl.mem t.index oid
  then raise_s [%message "Order_book: duplicate oid" (oid : Order_id.t)]
;;

let execute t ~oid ~owner ~side ~limit ~sz ~tif ~reduce_only ~cloid ~time ~next_tid
  : Result.t
  =
  let local_ taker = { oid; owner; side; limit; cloid; time; next_tid } in
  let { unfilled = remaining; rev_fills; rev_expired; stop } = sweep t taker sz [] [] in
  let fills = List.rev rev_fills in
  (* [List.rev []] returns the same immediate, so no-self-trade calls allocate nothing
     extra here. *)
  let expired_makers = List.rev rev_expired in
  let filled = Size.( - ) sz remaining in
  let status : Status.t =
    match stop, (tif : Tif.t) with
    | Done, _ -> Filled
    | Self_trade, _ -> Cancelled Self_trade
    | Exhausted, (Ioc | Alo) -> Cancelled Ioc_unfilled
    | Exhausted, Gtc ->
      rest
        t
        { oid
        ; owner
        ; side
        ; px = limit
        ; remaining
        ; orig_sz = sz
        ; timestamp = time
        ; reduce_only
        ; cloid
        };
      Resting
  in
  { fills; status; filled; remaining; expired_makers }
;;

let add_limit
  t
  ~oid
  ~owner
  ~side
  ~px
  ~sz
  ~tif
  ?(reduce_only = false)
  ?cloid
  ~time
  ~next_tid
  ()
  : Result.t
  =
  check_new_order t ~oid ~sz;
  if not (Price.is_positive px)
  then raise_s [%message "Order_book: price must be positive" (px : Price.t)];
  match (tif : Tif.t) with
  | Alo ->
    let would_cross =
      match best_level t (Side.flip side) with
      | None -> false
      | Some best -> crosses side ~limit:px best.px
    in
    if would_cross
    then
      { fills = []
      ; status = Would_cross
      ; filled = Size.zero
      ; remaining = sz
      ; expired_makers = []
      }
    else (
      rest
        t
        { oid
        ; owner
        ; side
        ; px
        ; remaining = sz
        ; orig_sz = sz
        ; timestamp = time
        ; reduce_only
        ; cloid
        };
      { fills = []
      ; status = Resting
      ; filled = Size.zero
      ; remaining = sz
      ; expired_makers = []
      })
  | Gtc | Ioc ->
    execute t ~oid ~owner ~side ~limit:px ~sz ~tif ~reduce_only ~cloid ~time ~next_tid
;;

let market_limit_px t ~side ~slippage_bps =
  best_level t (Side.flip side)
  |> Option.map ~f:(fun (best : Level.t) ->
    let units = Price.to_units best.px in
    (* One basis point is [10^4] units of [10^-8]. *)
    let delta = Fixed_decimal.mul_units units (slippage_bps * 10_000) in
    match (side : Side.t) with
    | Buy -> Price.of_units (units + delta)
    | Sell -> Price.of_units (Int.max 0 (units - delta)))
;;

let market
  t
  ~oid
  ~owner
  ~side
  ~sz
  ~slippage_bps
  ?(reduce_only = false)
  ?cloid
  ~time
  ~next_tid
  ()
  : Result.t
  =
  check_new_order t ~oid ~sz;
  match market_limit_px t ~side ~slippage_bps with
  | None ->
    { fills = []
    ; status = Cancelled Ioc_unfilled
    ; filled = Size.zero
    ; remaining = sz
    ; expired_makers = []
    }
  | Some limit ->
    execute t ~oid ~owner ~side ~limit ~sz ~tif:Ioc ~reduce_only ~cloid ~time ~next_tid
;;

let find t oid =
  Hashtbl.find_and_call
    t.index
    oid
    ~if_found:(fun (node : Level.node) -> Some node.order)
    ~if_not_found:(fun _ -> None)
;;

(* OxCaml: [find_and_call]'s callbacks are [local_], so these closures, which capture [t],
   live on the stack. The node holds its level, so no map lookup is needed. *)
let cancel t oid =
  Hashtbl.find_and_call
    t.index
    oid
    ~if_found:(fun (node : Level.node) ->
      unlink t node;
      Some node.order)
    ~if_not_found:(fun _ -> None)
;;

let levels_best_first t (side : Side.t) =
  match side with
  | Buy -> Map.to_sequence t.bids ~order:`Decreasing_key
  | Sell -> Map.to_sequence t.asks ~order:`Increasing_key
;;

let l2 t ~n_levels =
  (* [Sequence.take] raises on a negative count; treat it like 0. *)
  let n_levels = Int.max 0 n_levels in
  let side_l2 side =
    levels_best_first t side
    |> Fn.flip Sequence.take n_levels
    |> Sequence.map ~f:(fun (px, (level : Level.t)) ->
      { L2.Level.px; sz = level.total; n = level.length })
    |> Sequence.to_list
  in
  side_l2 Buy, side_l2 Sell
;;

let iter t ~(f @ local) =
  (* OxCaml: [f] is a [local_] closure, and Base's [Map.iter] / [Queue.iter] accept local
     closures too, so the wrapper closures below stay on the stack. *)
  let visit_level (level : Level.t) = Level.iter level ~f in
  Map.fold_right t.bids ~init:() ~f:(fun ~key:_ ~data () -> visit_level data);
  Map.iter t.asks ~f:visit_level [@nontail]
;;

let orders t =
  let acc = ref [] in
  iter t ~f:(fun o -> acc := o :: !acc);
  List.rev !acc
;;

let length t = Hashtbl.length t.index
let is_empty t = Hashtbl.is_empty t.index

let invariant t =
  let count = ref 0 in
  let check_side (side : Side.t) levels =
    Map.iteri levels ~f:(fun ~key:px ~data:(level : Level.t) ->
      if Level.is_empty level
      then raise_s [%message "empty level" (side : Side.t) (px : Price.t)];
      let total = ref Size.zero in
      let length = ref 0 in
      let rec walk (prev : Level.node or_null) (cur : Level.node or_null) =
        match cur with
        | Null ->
          (match prev, level.tail with
           | Null, Null -> ()
           | This p, This tail when phys_equal p tail -> ()
           | _ -> raise_s [%message "level tail is not the last node" (px : Price.t)])
        | This node ->
          let o = node.order in
          (match prev, node.prev with
           | Null, Null -> ()
           | This p, This p' when phys_equal p p' -> ()
           | _ -> raise_s [%message "broken prev link" (o : Resting_order.t)]);
          if not (phys_equal node.level level)
          then raise_s [%message "node points to another level" (o : Resting_order.t)];
          if not (Size.is_positive o.remaining)
          then raise_s [%message "non-positive remaining" (o : Resting_order.t)];
          if not (Price.equal o.px px && Side.equal o.side side)
          then raise_s [%message "order on wrong level" (o : Resting_order.t)];
          (match Hashtbl.find t.index o.oid with
           | Some n when phys_equal n node -> ()
           | _ -> raise_s [%message "order missing from index" (o : Resting_order.t)]);
          incr count;
          incr length;
          total := Size.( + ) !total o.remaining;
          walk cur node.next
      in
      walk Null level.head;
      if !length <> level.length
      then raise_s [%message "level length mismatch" (px : Price.t)];
      if not (Size.equal !total level.total)
      then raise_s [%message "level total mismatch" (px : Price.t)])
  in
  check_side Buy t.bids;
  check_side Sell t.asks;
  let check_top side top expected =
    match top, expected with
    | None, None -> ()
    | Some (top : Level.t), Some (_, expected) when phys_equal top expected -> ()
    | _ -> raise_s [%message "stale best level cache" (side : Side.t)]
  in
  check_top Buy t.top_bid (Map.max_elt t.bids);
  check_top Sell t.top_ask (Map.min_elt t.asks);
  if !count <> Hashtbl.length t.index
  then raise_s [%message "index has stale entries" (!count : int)];
  let check_or_null name (opt : Price.t option) (n : Price.t or_null) =
    match opt, n with
    | None, Null -> ()
    | Some a, This b when Price.equal a b -> ()
    | _ -> raise_s [%message "or_null query disagrees with option query" (name : string)]
  in
  check_or_null "best_bid" (best_bid t) (best_bid_or_null t);
  check_or_null "best_ask" (best_ask t) (best_ask_or_null t);
  check_or_null "mid" (mid t) (mid_or_null t);
  match best_bid t, best_ask t with
  | Some b, Some a when Price.( >= ) b a ->
    raise_s [%message "crossed book" (b : Price.t) (a : Price.t)]
  | _ -> ()
;;
