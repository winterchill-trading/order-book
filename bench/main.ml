open! Core
open! Exchange_core
open Core_bench

(* A book with [levels_per_side] bids and asks, one maker of size 10 per level, prices in
   whole units: bids [9_999 .. 10_000 - levels_per_side], asks [10_001 ..]. The best ask
   is a deep maker so a small taker never empties it. *)
let levels_per_side = 500
let maker = Account.of_string (sprintf "0x%040x" 1)
let taker = Account.of_string (sprintf "0x%040x" 2)
let next_tid () = Trade_id.of_int 0

module Ids = struct
  let next = ref 0

  let fresh () =
    incr next;
    Order_id.of_int !next
  ;;
end

let add book ?(owner = maker) ?(tif = Tif.Gtc) side px sz =
  Order_book.add_limit
    book
    ~oid:(Ids.fresh ())
    ~owner
    ~side
    ~px:(Price.of_int px)
    ~sz:(Size.of_int sz)
    ~tif
    ~time:0
    ~next_tid
    ()
;;

let best_bid_px = 10_000
let best_ask_px = 10_001

let make_book () =
  let book = Order_book.create (Symbol.of_string "BTC") in
  for i = 0 to levels_per_side - 1 do
    ignore (add book Buy (best_bid_px - i) 10 : Order_book.Result.t);
    let sz = if i = 0 then 1_000_000_000 else 10 in
    ignore (add book Sell (best_ask_px + i) sz : Order_book.Result.t)
  done;
  book
;;

let oid_exn (r : Order_book.Result.t) oid =
  match r.status with
  | Resting -> oid
  | _ -> raise_s [%message "expected a resting order" (r : Order_book.Result.t)]
;;

(* Submit a passive bid into an existing level 250 ticks deep, then cancel it. *)
let submit_and_cancel book () =
  let oid = Order_id.of_int (!Ids.next + 1) in
  let oid = oid_exn (add book Buy (best_bid_px - 250) 1) oid in
  ignore (Order_book.cancel book oid : Order_book.Resting_order.t option)
;;

(* Submit a passive bid at a new price (creating a level), then cancel it (removing it). *)
let submit_new_level_and_cancel book () =
  let oid = Order_id.of_int (!Ids.next + 1) in
  let oid = oid_exn (add book Buy (best_bid_px - levels_per_side - 10) 1) oid in
  ignore (Order_book.cancel book oid : Order_book.Resting_order.t option)
;;

(* An IOC buy of 1 against the deep best ask: one fill, the book shape is unchanged. *)
let match_one book () =
  ignore (add book ~owner:taker ~tif:Ioc Buy best_ask_px 1 : Order_book.Result.t)
;;

(* An IOC sell sweeping the 10 best bid levels (10 fills, 10 levels removed), then the
   makers are put back. *)
let sweep_ten book () =
  ignore (add book ~owner:taker ~tif:Ioc Sell (best_bid_px - 9) 100 : Order_book.Result.t);
  for i = 0 to 9 do
    ignore (add book Buy (best_bid_px - i) 10 : Order_book.Result.t)
  done
;;

let l2_ten book () =
  ignore (Order_book.l2 book ~n_levels:10 : L2.Level.t list * L2.Level.t list)
;;

let best_bid book () = ignore (Order_book.best_bid book : Price.t option)

let () =
  let book = make_book () in
  Command_unix.run
    (Bench.make_command
       [ Bench.Test.create ~name:"submit+cancel (existing level)" (submit_and_cancel book)
       ; Bench.Test.create
           ~name:"submit+cancel (new level)"
           (submit_new_level_and_cancel book)
       ; Bench.Test.create ~name:"match 1 fill (IOC)" (match_one book)
       ; Bench.Test.create ~name:"sweep 10 levels + refill" (sweep_ten book)
       ; Bench.Test.create ~name:"l2 10 levels" (l2_ten book)
       ; Bench.Test.create ~name:"best_bid" (best_bid book)
       ])
;;
