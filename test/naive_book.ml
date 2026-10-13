open! Core
open! Exchange_core

type order =
  { oid : Order_id.t
  ; owner : Account.t
  ; side : Side.t
  ; px : Price.t
  ; remaining : Size.t
  ; seq : int
  }

type t =
  { stp : Order_book.Stp.t
  ; mutable orders : order list
  ; mutable seq : int
  }

let create ?(stp = Order_book.Stp.default) () = { stp; orders = []; seq = 0 }

module Fill = struct
  type t =
    { maker_oid : Order_id.t
    ; px : Price.t
    ; sz : Size.t
    }
  [@@deriving sexp_of, compare, equal]
end

module Outcome = struct
  type t =
    { fills : Fill.t list
    ; status : Order_book.Status.t
    ; remaining : Size.t
    ; expired : Order_id.t list
    }
  [@@deriving sexp_of, compare, equal]
end

(* Best first: highest bid, lowest ask; then oldest first. *)
let priority (side : Side.t) a b =
  let by_px =
    match side with
    | Buy -> Price.compare b.px a.px
    | Sell -> Price.compare a.px b.px
  in
  if by_px <> 0 then by_px else Int.compare a.seq b.seq
;;

let side_orders t side =
  List.filter t.orders ~f:(fun o -> Side.equal o.side side)
  |> List.sort ~compare:(priority side)
;;

let crosses (taker_side : Side.t) ~limit px =
  match taker_side with
  | Buy -> Price.( <= ) px limit
  | Sell -> Price.( >= ) px limit
;;

let replace t (o : order) =
  t.orders
  <- List.filter_map t.orders ~f:(fun o' ->
       if Order_id.equal o'.oid o.oid
       then if Size.is_zero o.remaining then None else Some o
       else Some o')
;;

let rest t ~oid ~owner ~side ~px ~remaining =
  t.seq <- t.seq + 1;
  t.orders <- t.orders @ [ { oid; owner; side; px; remaining; seq = t.seq } ]
;;

let remove t oid =
  t.orders <- List.filter t.orders ~f:(fun o -> not (Order_id.equal o.oid oid))
;;

(* Matches one maker at a time against the current best, re-reading the book each step. An
   own maker is handled by the policy: stop, or drop it and continue, or both. *)
let rec sweep t ~owner ~side ~limit remaining fills expired =
  let finish stop = remaining, List.rev fills, List.rev expired, stop in
  if Size.is_zero remaining
  then finish `Done
  else (
    match side_orders t (Side.flip side) with
    | best :: _ when crosses side ~limit best.px ->
      if Account.equal best.owner owner
      then (
        match t.stp with
        | Cancel_taker -> finish `Self_trade
        | Expire_maker ->
          remove t best.oid;
          sweep t ~owner ~side ~limit remaining fills (best.oid :: expired)
        | Cancel_both ->
          remove t best.oid;
          remaining, List.rev fills, List.rev (best.oid :: expired), `Self_trade)
      else (
        let sz = Size.min remaining best.remaining in
        replace t { best with remaining = Size.( - ) best.remaining sz };
        sweep
          t
          ~owner
          ~side
          ~limit
          (Size.( - ) remaining sz)
          ({ Fill.maker_oid = best.oid; px = best.px; sz } :: fills)
          expired)
    | _ -> finish `Exhausted)
;;

let execute t ~oid ~owner ~side ~limit ~sz ~(tif : Tif.t) : Outcome.t =
  let remaining, fills, expired, stop = sweep t ~owner ~side ~limit sz [] [] in
  let status : Order_book.Status.t =
    match stop, tif with
    | `Done, _ -> Filled
    | `Self_trade, _ -> Cancelled Self_trade
    | `Exhausted, (Ioc | Alo) -> Cancelled Ioc_unfilled
    | `Exhausted, Gtc ->
      rest t ~oid ~owner ~side ~px:limit ~remaining;
      Resting
  in
  { fills; status; remaining; expired }
;;

let add_limit t ~oid ~owner ~side ~px ~sz ~(tif : Tif.t) : Outcome.t =
  match tif with
  | Alo ->
    let would_cross =
      List.exists
        (side_orders t (Side.flip side))
        ~f:(fun o -> crosses side ~limit:px o.px)
    in
    if would_cross
    then { fills = []; status = Would_cross; remaining = sz; expired = [] }
    else (
      rest t ~oid ~owner ~side ~px ~remaining:sz;
      { fills = []; status = Resting; remaining = sz; expired = [] })
  | Gtc | Ioc -> execute t ~oid ~owner ~side ~limit:px ~sz ~tif
;;

let market t ~oid ~owner ~side ~sz ~slippage_bps : Outcome.t =
  match side_orders t (Side.flip side) with
  | [] -> { fills = []; status = Cancelled Ioc_unfilled; remaining = sz; expired = [] }
  | best :: _ ->
    let units = Price.to_units best.px in
    let delta = units * slippage_bps / 10_000 in
    let limit =
      match (side : Side.t) with
      | Buy -> Price.of_units (units + delta)
      | Sell -> Price.of_units (Int.max 0 (units - delta))
    in
    execute t ~oid ~owner ~side ~limit ~sz ~tif:Ioc
;;

let cancel t oid =
  let present = List.exists t.orders ~f:(fun o -> Order_id.equal o.oid oid) in
  remove t oid;
  present
;;

let l2 t =
  let side_l2 side =
    side_orders t side
    |> List.group ~break:(fun a b -> not (Price.equal a.px b.px))
    |> List.map ~f:(fun level ->
      { L2.Level.px = (List.hd_exn level).px
      ; sz = Size.sum (List.map level ~f:(fun o -> o.remaining))
      ; n = List.length level
      })
  in
  side_l2 Buy, side_l2 Sell
;;
