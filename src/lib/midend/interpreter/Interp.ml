open Batteries
open Syntax
open InterpState

let initial_state (pp : Preprocess.t) (spec : InterpSpec.t) =
  let nst =
    { (State.create spec.config) with
      event_sorts = Env.map fst pp.events
    ; switches = Array.init spec.num_switches (fun _ -> State.empty_state ())
    ; links = spec.links
    }
  in
  (* Add builtins *)
  List.iter
    (fun f -> State.add_global_function f nst)
    (System.defs @ Events.defs @ Counters.defs @ Arrays.defs @ PairArrays.defs);
  (* Add externs *)
  List.iteri
    (fun i exs -> Env.iter (fun cid v -> State.add_global i cid (V v) nst) exs)
    spec.externs;
  (* Add foreign functions *)
  Env.iter
    (fun cid fval ->
      Array.iteri (fun i _ -> State.add_global i cid fval nst) nst.switches)
    spec.extern_funs;
  (* Add events *)
  List.iter
    (fun (event, locs) ->
      List.iter
        (fun (loc, port) -> State.push_input_event loc port event nst)
        locs)
    spec.events;
  nst
;;

let initialize renaming spec_file ds =
  let pp, ds = Preprocess.preprocess ds in
  (* Also initializes the Python environment *)
  let spec = InterpSpec.parse pp renaming spec_file in
  let nst = initial_state pp spec in
  let nst = InterpCore.process_decls nst ds in
  nst
;;

(* 
  What does it take for an interactive interpreter? 
  - asynchronous processing. We need a background 
    process that modifies nst.event_queue...

  - Alternately...
    before processing each event, call a "read newline"
    function, that checks if there are any input events
    on stdin.

  - The problem is time... When an event comes in from stdin, 
    what time do we assign it? 
    - The only option that makes sense is "now" 
        -- the current simulation time. 


*)

let simulate (nst : State.network_state) =
  Console.report
  @@ "Using random seed: "
  ^ string_of_int nst.config.random_seed
  ^ "\n";
  Random.init nst.config.random_seed;
  (* 
    the interpret event loop
    loop through the switches (indexed by idx), 
    process all events that arrived before state.current time
    increment current_time by 1 each time we arrive at switch idx=0
  *)
  let rec interp_events idx nst =
(*     let input_event = InterpStream.get_event () in 
    print_endline @@ "got input event: "^input_event; *)
    match State.next_time nst with
    | None -> nst
    | Some t ->
      (* Increment the current time *)
      print_endline (Printf.sprintf "[switch %i @ time %i] " idx t);
      (* when we reach switch idx = 0, increment the time by 1. *)
      let nst =
        if idx = 0
        then { nst with current_time = max t (nst.current_time + 1) }
        else nst
      in
      if nst.current_time > nst.config.max_time
      then nst
      else (
        match State.next_event idx nst with
        | None -> interp_events ((idx + 1) mod Array.length nst.switches) nst
        | Some (event, port) ->
          (match Env.find_opt event.eid nst.handlers with
          | None -> error @@ "No handler for event " ^ Cid.to_string event.eid
          | Some handler ->
            Printf.printf
              "t=%d: Handling %sevent %s at switch %d, port %d\n"
              nst.current_time
              (match Env.find event.eid nst.event_sorts with
              | EEntry _ -> "entry "
              | _ -> "")
              (CorePrinting.event_to_string event)
              idx
              port;
            handler nst idx port event);
          interp_events ((idx + 1) mod Array.length nst.switches) nst)
  in
  let nst = interp_events 0 nst in
  nst
;;
