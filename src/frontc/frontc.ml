module E = Errormsg
open Trace
open Pretty

(* Output management *)
let out : out_channel option ref = ref None
let close_me = ref false

let close_output _ =
  match !out with
    None -> ()
  | Some o -> begin
      flush o;
      if !close_me then close_out o else ();
      close_me := false
  end

let set_output filename =
  close_output ();
  (try out := Some (open_out filename)
  with (Sys_error msg) ->
    output_string stderr ("Error while opening output: " ^ msg); exit 1);
  close_me := true

   (* Signal that we are in MS VC mode *)
let setMSVCMode () =
  Cprint.msvcMode := true

(* filename for patching *)
let patchFileName : string ref = ref ""      (* by default do no patching *)

(* patching file contents *)
let patchFile : Cabs.file option ref = ref None

(* whether to print a file of prototypes after parsing *)
let doPrintProtos : bool ref = ref false

(* this seems like something that should be built-in.. *)
let isNone (o : 'a option) : bool =
begin
  match o with
  | Some _ -> false
  | None -> true
end

(*
** Argument definition
*)
let args : (string * Arg.spec * string) list =
[
  "--cabsout", Arg.String set_output, "Output file";
  "--cabsindent", Arg.Int Cprint.set_tab, "Identation step";
  "--cabswidth", Arg.Int Cprint.set_width, "Page width";
  "--cabscounters", Arg.Unit (fun _ -> Cprint.printCounters := true),
                   "Print invocation counters for functions";
  "--printComments", Arg.Unit (fun _ -> Cprint.printComments := true),
             "print cabs tree structure in comments in cabs output";
  "--patchFile", Arg.String (fun pf -> patchFileName := pf),
             "name the file containing patching transformations";
  "--printProtos", Arg.Unit (fun _ -> doPrintProtos := true),
             "print prototypes to safec.proto.h after parsing";
]

exception ParseError of string


(* parse, and apply patching *)
let rec parse_to_cabs fname =
begin
  (* parse the patch file if it isn't parsed already *)
  if ((!patchFileName <> "") && (isNone !patchFile)) then (
    (* parse the patch file *)
    patchFile := Some(parse_to_cabs_inner !patchFileName)
  );

  (* now parse the file we came here to parse *)
  let cabs = parse_to_cabs_inner fname in

  (* and apply the patch file, return transformed file *)
  let patched = (* match !patchFile with

    | Some(pf) -> (
        (* save old value of out so I can use it for debugging during patching *)
        let oldOut = !out in

        (* reset out so we don't try to print the patch file to it *)
        out := None;

        (trace "patch" (dprintf "newpatching %s\n" fname));
        let result = (Stats.time "newpatch" (Patch.applyPatch pf) cabs) in

        (* restore out *)
        Cprint.flush ();
        out := oldOut;

        result
      )
    | None -> *) cabs
  in

  (* print it ... *)
  (match !out with
    Some o -> begin
      (trace "sm" (dprintf "writing the cabs output\n"));
      output_string o ("/* Generated by Frontc */\n");
      Stats.time "printCABS" (Cprint.print o) patched;
      close_output ();
    end
  | None -> ());
  if !E.hadErrors then
    raise Parsing.Parse_error;

  (* and return the patched source *)
  patched
end


(* just parse *)
and parse_to_cabs_inner (fname : string) =
  try
    if !E.verboseFlag then ignore (E.log "Frontc is parsing %s\n" fname);
    flush !E.logChannel;
    let file = open_in fname in
    E.hadErrors := false;
    let lexbuf: Lexing.lexbuf = Clexer.init fname file in
    let cabs =
      Stats.time "parse"
        (Cparser.file Clexer.initial) lexbuf in
    close_in file;
    if !E.verboseFlag then ignore (E.log "Frontc finished parsing %s\n" fname);
    cabs
  with (Sys_error msg) -> begin
    ignore (E.log "Cannot open %s : %s\n" fname msg);
    close_output ();
    raise (ParseError("Cannot open " ^ fname ^ ": " ^ msg ^ "\n"))
  end
  | Parsing.Parse_error -> begin
      ignore (E.log "Parsing error\n");
      close_output ();
      raise (ParseError("Parse error"))
  end
  | e -> begin
      ignore (E.log "Caught %s while parsing\n" (Printexc.to_string e));
      raise e
  end

  
(* print to safec.proto.h the prototypes of all functions that are defined *)
let printPrototypes (file : Cabs.file) : unit =
begin
  (*ignore (E.log "file has %d defns\n" (List.length file));*)

  let chan = open_out "safec.proto.h" in
  ignore (fprintf chan "/* generated prototypes file, %d defs */\n" (List.length file));
  Cprint.out := chan;

  let counter : int ref = ref 0 in

  let rec loop (d : Cabs.definition) = begin
    match d with
    | Cabs.FUNDEF(name, _, loc) -> (
        match name with
        | (_, (funcname, Cabs.PROTO(_,_,_), _)) -> (
            incr counter;          
            ignore (fprintf chan "\n/* %s from %s:%d */\n"
                                 funcname loc.Cabs.filename loc.Cabs.lineno);
            flush chan;
            Cprint.print_single_name name;
            Cprint.print_unescaped_string ";";
            Cprint.force_new_line ();
            Cprint.flush ()
          )
        | _ -> ()
      )

    | _ -> ()
  end in
  (List.iter loop file);

  ignore (fprintf chan "\n/* wrote %d prototypes */\n" !counter);
  close_out chan;
  ignore (E.log "printed %d prototypes from %d defns to safec.proto.h\n"
                !counter (List.length file))
end



let parse fname =
  (trace "sm" (dprintf "beginning parsing to Cabs\n"));
  let cabs = parse_to_cabs fname in
  (* Now convert to CIL *)
  fun _ ->
    (trace "sm" (dprintf "beginning conversion to Cil\n"));
    let cil = Stats.time "conv" (Cabs2cil.convFile fname) cabs in
    if !doPrintProtos then (printPrototypes cabs);
    if !E.verboseFlag then 
      ignore (E.log "FrontC finished conversion of %s to CIL\n" fname);
    cil








