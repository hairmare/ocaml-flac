
let output_int chan n =
  output_char chan (char_of_int ((n lsr 0) land 0xff));
  output_char chan (char_of_int ((n lsr 8) land 0xff));
  output_char chan (char_of_int ((n lsr 16) land 0xff));
  output_char chan (char_of_int ((n lsr 24) land 0xff))


let output_short chan n =
  output_char chan (char_of_int ((n lsr 0) land 0xff));
  output_char chan (char_of_int ((n lsr 8) land 0xff))

let progress_bar =
  let spin = ref 0 in
    (
      fun title pos tot ->
        let nbeq = 40 in
        let n = min (100. *. (float_of_int pos) /. (float_of_int tot)) 100. in
        Printf.printf "\r%s " title;
        if tot > 0 then
          begin
            Printf.printf "%6.2f%% [" n;
            let e = int_of_float (n /. 100. *. (float_of_int nbeq)) in
            for i = 1 to e do Printf.printf "=" done;
            if e != nbeq then Printf.printf ">";
            for i = e + 2 to nbeq do Printf.printf " " done;
            Printf.printf "] "
         end ;
          incr spin;
          if !spin > 4 then spin := 1;
          Printf.printf "%c%!"
            (
              if tot > 0 && n = 100. then ' '
              else
                match !spin with
                  | 1 -> '|'
                  | 2 -> '/'
                  | 3 -> '-'
                  | 4 -> '\\'
                  | _ -> failwith "this did not happen"
            )
    )

let infile = ref "input.flac"
let outfile = ref "output.raw"
let ogg = ref false

let () =
  Arg.parse
    [
      "-o", Arg.Set_string outfile, "Output file";
      "-i", Arg.Set_string infile, "Input file";
      "-ogg", Arg.Bool (fun x -> ogg := x), "Ogg/flac file";
    ]
    ignore
    "decode [options]"

let () =
  let fd =
    Printf.printf "Opening input file %S\n%!" !infile;
    Unix.openfile !infile [Unix.O_RDONLY] 0o640
  in
  let oc =
    Printf.printf "Opening output file %S\n%!" !outfile;
    open_out !outfile
  in
  let read_f n =
    let s = String.create n in
    let ret = Unix.read fd s 0 n in
    s,ret
  in
  let (decoder,info),fill = 
   if not !ogg then
     Flac.Decoder.create read_f,(fun () -> failwith "should not happend")
   else
     let sync = Ogg.Sync.create read_f in
     let test_flac () = 
       (** Get First page *)
       let page = Ogg.Sync.read sync in
       (** Check wether this is a b_o_s *)
       if not (Ogg.Page.bos page) then raise Flac.Not_flac ;
       (** Create a stream with this ID *)
       let serial = Ogg.Page.serialno page in
       Printf.printf "Testing stream %nx\n" serial ;
       let os = Ogg.Stream.create ~serial () in
       Ogg.Stream.put_page os page ;
       let packet = Ogg.Stream.get_packet os in
       (** Test header. Do not catch anything, first page should be sufficient *)
       if not (Ogg_flac.Decoder.check_packet packet) then
         raise Not_found;
       Printf.printf "Got a flac stream !\n" ;
       let fill () =
         let page = Ogg.Sync.read sync in
         if Ogg.Page.serialno page = serial then
           Ogg.Stream.put_page os page
       in
       let dec = Ogg_flac.Decoder.create packet os in
       let rec info () =
        try 
         Ogg_flac.Decoder.init dec 
        with
          | Ogg.Not_enough_data -> fill (); info ()
       in
       info (),fill
     in
     (** Now find a flac stream *)
     let rec init () =
       try
         test_flac ()
       with
         | Not_found ->
            ( Printf.printf "This stream was not flac..\n";
              init () )
         | Flac.Not_flac ->
            ( Printf.printf "No flac stream was found..\n%!";
              raise Flac.Not_flac )
     in
     init ()
  in 
  Printf.printf "Stream info:\n";
  Printf.printf "sample rate: %i\n" info.Flac.Decoder.sample_rate ;
  Printf.printf "bits per sample: %i\n" info.Flac.Decoder.bits_per_sample ;
  Printf.printf "channels: %i\n" info.Flac.Decoder.channels ;
  Printf.printf "total samples: %s\n" (Int64.to_string info.Flac.Decoder.total_samples) ;
  Printf.printf "md5sum: " ;
  String.iter (fun c -> Printf.printf "%x" (int_of_char c)) info.Flac.Decoder.md5sum ;
  Printf.printf "\n";
  if info.Flac.Decoder.bits_per_sample <> 16 then
    failwith "Unsupported bits per sample." ;
  let srate = 
    info.Flac.Decoder.sample_rate
  in
  let chans = 
    info.Flac.Decoder.channels
  in
  let datalen = 
    (Int64.to_int info.Flac.Decoder.total_samples) * chans * 2
  in
  let () = 
    match Flac.Decoder.comments decoder with
      | None -> Printf.printf "No comment found..\n" ;
      | Some (vendor,comments) -> 
           Printf.printf "Metadata:\n";
           List.iter (fun (x,y) -> Printf.printf "%s: %s\n" x y) comments ;
           Printf.printf "VENDOR: %s\n" vendor 
  in
  output_string oc "RIFF";
  output_int oc (4 + 24 + 8 + datalen);
  output_string oc "WAVE";
  output_string oc "fmt ";
  output_int oc 16;
  output_short oc 1; (* WAVE_FORMAT_PCM *)
  output_short oc chans; (* channels *)
  output_int oc srate; (* freq *)
  output_int oc (srate * chans * 2); (* bytes / s *)
  output_short oc (chans * 2); (* block alignment *)
  output_short oc 16; (* bits per sample *)
  output_string oc "data";
  output_int oc datalen;
  let pos = ref 0 in
  let rec decode () =
    try
      let ret = Flac.Decoder.read_pcm decoder in
      pos := !pos + (String.length ret) ;
      progress_bar "Decoding FLAC file:" !pos datalen ;
      output_string oc ret ;
      flush oc ;
      match Flac.Decoder.state decoder with
        | `End_of_stream -> Printf.printf "\n"
        | _ -> decode ()
    with
      | Ogg.Not_enough_data -> fill (); decode ()
  in
  begin
   try 
     decode () 
   with Ogg.Not_enough_data -> ()
  end ;
  Printf.printf "\n";
  close_out oc ;
  Unix.close fd ;
  (* We have global root values
   * so we need to do two full major.. *)
  Gc.full_major () ;
  Gc.full_major () ;
