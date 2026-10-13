open! Core
open! Exchange_core
open Helpers

(* Minor-heap words allocated per operation on a 1000-level book (500 bids, 500 asks, one
   maker per level, a deep best ask). Each case leaves the book unchanged so it can be
   repeated. The numbers are what the compiler produces today; a change here is a change
   in allocation behaviour. *)

let maker = addr 1
let taker = addr 2
let next_tid () = Trade_id.of_int 0
let next_oid = ref 0

let fresh_oid () =
  incr next_oid;
  Order_id.of_int !next_oid
;;

let add book ?(owner = maker) ?(tif = Tif.Gtc) side px sz =
  Order_book.add_limit
    book
    ~oid:(fresh_oid ())
    ~owner
    ~side
    ~px:(Price.of_int px)
    ~sz:(Size.of_int sz)
    ~tif
    ~time:0
    ~next_tid
    ()
;;

let make_book () =
  let book = Order_book.create btc in
  for i = 0 to 499 do
    ignore (add book Buy (10_000 - i) 10 : Order_book.Result.t);
    let sz = if i = 0 then 1_000_000_000 else 10 in
    ignore (add book Sell (10_001 + i) sz : Order_book.Result.t)
  done;
  (* The bid level at 9_900 holds 1000 orders, so cancelling the newest there would cost a
     pass over the level if removal were linear. *)
  for _ = 2 to 1_000 do
    ignore (add book Buy 9_900 10 : Order_book.Result.t)
  done;
  book
;;

let words_per_run f =
  let runs = 1_000 in
  (* Warm up once so one-off growth (hash table resize) is not counted. *)
  f ();
  let before = Gc.minor_words () in
  for _ = 1 to runs do
    f ()
  done;
  Float.iround_nearest_exn (Float.of_int (Gc.minor_words () - before) /. Float.of_int runs)
;;

let or_null_ignore : Price.t or_null -> unit = function
  | Null -> ()
  | This _ -> ()
;;

let%expect_test "minor words per operation" =
  let book = make_book () in
  let resting_oid = Order_id.of_int 3 in
  let cases =
    [ ("best_bid", fun () -> ignore (Order_book.best_bid book : Price.t option))
    ; ("best_ask", fun () -> ignore (Order_book.best_ask book : Price.t option))
    ; ("mid", fun () -> ignore (Order_book.mid book : Price.t option))
    ; ("best_bid_or_null", fun () -> or_null_ignore (Order_book.best_bid_or_null book))
    ; ("best_ask_or_null", fun () -> or_null_ignore (Order_book.best_ask_or_null book))
    ; ("mid_or_null", fun () -> or_null_ignore (Order_book.mid_or_null book))
    ; ( "find"
      , fun () ->
          ignore (Order_book.find book resting_oid : Order_book.Resting_order.t option) )
    ; ( "l2 10 levels"
      , fun () ->
          ignore (Order_book.l2 book ~n_levels:10 : L2.Level.t list * L2.Level.t list) )
    ; ( "match 1 fill (IOC)"
      , fun () ->
          ignore (add book ~owner:taker ~tif:Ioc Buy 10_001 1 : Order_book.Result.t) )
    ; ( "submit + cancel"
      , fun () ->
          let oid = Order_id.of_int (!next_oid + 1) in
          ignore (add book Buy 9_750 1 : Order_book.Result.t);
          ignore (Order_book.cancel book oid : Order_book.Resting_order.t option) )
    ; ( "submit + cancel deep"
      , fun () ->
          let oid = Order_id.of_int (!next_oid + 1) in
          ignore (add book Buy 9_900 1 : Order_book.Result.t);
          ignore (Order_book.cancel book oid : Order_book.Resting_order.t option) )
    ]
  in
  List.iter cases ~f:(fun (name, f) -> printf "%-20s %4d\n" name (words_per_run f));
  Order_book.invariant book;
  [%expect
    {|
    best_bid                2
    best_ask                2
    mid                     2
    best_bid_or_null        0
    best_ask_or_null        0
    mid_or_null             0
    find                    2
    l2 10 levels          653
    match 1 fill (IOC)     26
    submit + cancel        37
    submit + cancel deep   37
    |}]
;;
