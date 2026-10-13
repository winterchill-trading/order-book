open! Core
open! Exchange_core
open Helpers

(* Bisimulation: drive [Order_book] and the naive list matcher with the same operations
   and require identical fills, statuses, remainders, cancel results and full L2 after
   every step. *)

let n_oids = 64

let outcome_of_result (r : Order_book.Result.t) : Naive_book.Outcome.t =
  { fills =
      List.map r.fills ~f:(fun (f : Order_book.Fill.t) ->
        { Naive_book.Fill.maker_oid = f.maker_oid; px = f.px; sz = f.sz })
  ; status = r.status
  ; remaining = r.remaining
  ; expired = List.map r.expired_makers ~f:(fun (o : Order_book.Resting_order.t) -> o.oid)
  }
;;

let step ~book ~model ~oid (op : Op.t) =
  let next_tid () = Trade_id.of_int 0 in
  (match op with
   | Limit { owner; side; px; sz; tif } ->
     let owner = addr owner
     and px = Price.of_int px
     and sz = Size.of_int sz in
     let real =
       Order_book.add_limit book ~oid ~owner ~side ~px ~sz ~tif ~time:0 ~next_tid ()
     in
     let naive = Naive_book.add_limit model ~oid ~owner ~side ~px ~sz ~tif in
     [%test_result: Naive_book.Outcome.t] (outcome_of_result real) ~expect:naive
   | Market { owner; side; sz } ->
     let owner = addr owner
     and sz = Size.of_int sz in
     let real =
       Order_book.market book ~oid ~owner ~side ~sz ~slippage_bps:300 ~time:0 ~next_tid ()
     in
     let naive = Naive_book.market model ~oid ~owner ~side ~sz ~slippage_bps:300 in
     [%test_result: Naive_book.Outcome.t] (outcome_of_result real) ~expect:naive
   | Cancel i ->
     let oid = Order_id.of_int (1 + (i % n_oids)) in
     [%test_result: bool]
       (Option.is_some (Order_book.cancel book oid))
       ~expect:(Naive_book.cancel model oid));
  [%test_result: L2.Level.t list * L2.Level.t list]
    (Order_book.l2 book ~n_levels:Int.max_value)
    ~expect:(Naive_book.l2 model);
  Order_book.invariant book
;;

let run ?(stp = Order_book.Stp.default) ops =
  let book = Order_book.create ~stp btc in
  let model = Naive_book.create ~stp () in
  List.iteri ops ~f:(fun i op -> step ~book ~model ~oid:(Order_id.of_int (i + 1)) op)
;;

let%test_unit "order book and naive matcher agree on random operation sequences" =
  Quickcheck.test
    ~trials:1000
    ~sexp_of:[%sexp_of: Op.t list]
    ~examples:Op.examples
    (Quickcheck.Generator.list_with_length n_oids Op.gen)
    ~f:run
;;

(* The same property under every self-trade prevention policy. Owners are drawn from four
   accounts, so own makers are reached often. *)
let%test_unit "order book and naive matcher agree under each self-trade policy" =
  List.iter Order_book.Stp.all ~f:(fun stp ->
    Quickcheck.test
      ~trials:1000
      ~sexp_of:[%sexp_of: Op.t list]
      ~examples:Op.examples
      (Quickcheck.Generator.list_with_length n_oids Op.gen)
      ~f:(run ~stp))
;;

let%test_unit "fuzz: random byte strings decoded into operations" =
  Quickcheck.test
    ~trials:1000
    ~sexp_of:[%sexp_of: string]
    ~examples:[ ""; "\000\000\000"; String.make 192 '\255'; String.make 192 '\007' ]
    (let open Quickcheck.Generator.Let_syntax in
     let%bind len = Int.gen_incl 0 (3 * n_oids) in
     String.gen_with_length len Char.quickcheck_generator)
    ~f:(fun s -> List.iter Order_book.Stp.all ~f:(fun stp -> run ~stp (Op.of_bytes s)))
;;

let%expect_test "byte decoding" =
  print_s [%sexp (Op.of_bytes "\000\021\009\006\001\002\007\005\000\010" : Op.t list)];
  [%expect
    {|
    ((Limit (owner 1) (side Sell) (px 105) (sz 2) (tif Ioc))
     (Market (owner 1) (side Sell) (sz 3)) (Cancel 5))
    |}]
;;
