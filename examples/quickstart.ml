(* A two-sided book, one crossing order, a cancel and an L2 snapshot. The same code is in
   the documentation of [Order_book]. *)

open! Core
open Exchange_core

let () =
  let book = Order_book.create (Symbol.of_string "BTC") in
  (* Trade ids are the caller's: here a counter. *)
  let next_tid =
    let n = ref 0 in
    fun () ->
      incr n;
      Trade_id.of_int !n
  in
  let maker = Account.of_string "maker" in
  let taker = Account.of_string "taker" in
  let limit ~oid ~owner ~side ~px ~sz ~time =
    Order_book.add_limit
      book
      ~oid:(Order_id.of_int oid)
      ~owner
      ~side
      ~px:(Price.of_string px)
      ~sz:(Size.of_string sz)
      ~tif:Gtc
      ~time
      ~next_tid
      ()
  in
  (* Two asks and a bid rest on an empty book. *)
  ignore
    (limit ~oid:1 ~owner:maker ~side:Sell ~px:"101" ~sz:"1" ~time:1 : Order_book.Result.t);
  ignore
    (limit ~oid:2 ~owner:maker ~side:Sell ~px:"102" ~sz:"2" ~time:2 : Order_book.Result.t);
  ignore
    (limit ~oid:3 ~owner:maker ~side:Buy ~px:"99" ~sz:"1" ~time:3 : Order_book.Result.t);
  (* A buy for 1.5 at 102 takes the 101 ask, then half of the 102 ask. *)
  let result = limit ~oid:4 ~owner:taker ~side:Buy ~px:"102" ~sz:"1.5" ~time:4 in
  List.iter result.fills ~f:(fun (fill : Order_book.Fill.t) ->
    printf
      "fill %s: %s at %s, maker order %s\n"
      (Trade_id.to_string fill.tid)
      (Size.to_string fill.sz)
      (Price.to_string fill.px)
      (Order_id.to_string fill.maker_oid));
  print_s [%sexp (result.status : Order_book.Status.t)];
  (* Cancelling returns the resting order, or [None] if it is gone. *)
  let cancelled = Order_book.cancel book (Order_id.of_int 3) in
  printf "cancelled order 3: %b\n" (Option.is_some cancelled);
  let bids, asks = Order_book.l2 book ~n_levels:5 in
  print_s [%sexp { bids : L2.Level.t list; asks : L2.Level.t list }];
  match Order_book.best_ask_or_null book with
  | This px -> printf "best ask %s\n" (Price.to_string px)
  | Null -> print_endline "no asks"
;;
