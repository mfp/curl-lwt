
open Printf
open Lwt

let section = Lwt_log.Section.make "curl_lwt"

type worker = {
  handle : Curl.t;
  mutable thread : Thread.t;
  start_task_channel : (int * exn option ref) Event.channel;
  mutable reuse : bool;
  mutable response_header : string option;
}

let () =
  Printexc.register_printer
    (function
         Curl.CurlException (code, n, s) ->
           Some (sprintf "Curl.CurlException (%S, %d, %S)" (Curl.strerror code) n s)
       | _ -> None)

let () = Curl.global_init Curl.CURLINIT_GLOBALALL

let recv_event ch = Event.sync (Event.receive ch)
let send_event_block ch ev = Event.sync (Event.send ch ev)
let try_send_event ch ev   = ignore (Event.poll (Event.send ch ev))

let max_threads = ref 20
let thread_count = ref 0
let workers = Queue.create ()
let waiters = Lwt_sequence.create ()

let get_max_threads ()     = !max_threads
let get_current_threads () = !thread_count

let get_free_workers () =
  Queue.length workers + max 0 (!max_threads - !thread_count)

let set_max_threads n =
  if n >= 1 then max_threads := n

let bprintf b fmt =
  let to_b = Format.formatter_of_buffer b in
    Format.fprintf to_b fmt

let worker_info w =
  let pp fmt = function
      Curl.CURLINFO_String s -> Format.fprintf fmt "%S" s
    | Curl.CURLINFO_Long n -> Format.fprintf fmt "%d" n
    | Curl.CURLINFO_Double f -> Format.fprintf fmt "%f" f
    | Curl.CURLINFO_StringList l ->
        Format.fprintf fmt "%s"
          ("[" ^ String.concat "; " (List.map (sprintf "%S") l) ^ "]") in

  let b = Buffer.create 120 in
  let output n what =
    bprintf b "%s: %a\n" n pp (Curl.getinfo w.handle what)
  in
    output "Effective URL" Curl.CURLINFO_EFFECTIVE_URL;
    output "Redirect URL" Curl.CURLINFO_REDIRECT_URL;
    output "Response code" Curl.CURLINFO_RESPONSE_CODE;
    output "Redirect count" Curl.CURLINFO_REDIRECT_COUNT;
    output "Total time" Curl.CURLINFO_TOTAL_TIME;
    output "DNS time" Curl.CURLINFO_NAMELOOKUP_TIME;
    output "Redirect time" Curl.CURLINFO_REDIRECT_TIME;
    output "Connect time" Curl.CURLINFO_CONNECT_TIME;
    output "Size upload" Curl.CURLINFO_SIZE_UPLOAD;
    output "Size download" Curl.CURLINFO_SIZE_DOWNLOAD;
    output "Speed upload" Curl.CURLINFO_SPEED_UPLOAD;
    output "Speed download" Curl.CURLINFO_SPEED_DOWNLOAD;
    output "Header size" Curl.CURLINFO_HEADER_SIZE;
    output "Request size" Curl.CURLINFO_REQUEST_SIZE;
    output "Content-length upload" Curl.CURLINFO_CONTENT_LENGTH_UPLOAD;
    output "Content-length download" Curl.CURLINFO_CONTENT_LENGTH_DOWNLOAD;
    output "Content-type" Curl.CURLINFO_CONTENT_TYPE;
    output "Num connects" Curl.CURLINFO_NUM_CONNECTS;
    bprintf b "Response header: %s%!"
      (match w.response_header with
           None -> "<None>\n"
         | Some s -> sprintf "\n%s\n" s);
    (* output "Local port" Curl.CURLINFO_LOCAL_PORT; *)
    (* output "Condition unmet" Curl.CURLINFO_CONDITION_UNMET; *)
    Buffer.contents b

let alarm_notice_period = ref 60
let get_alarm_notice_period () = !alarm_notice_period
let set_alarm_notice_period n  = if n > 0 then alarm_notice_period := n

let rec worker_loop w =
  let id, exn_r = recv_event w.start_task_channel in
  let timeout   =
    Lwt_preemptive.run_in_main
      (fun () ->
        return
          (Lwt_timeout.create !alarm_notice_period
             (fun () ->
                ignore begin try_lwt
                  Lwt_log.info_f ~section
                    "Curl request took longer than %ds.\n\
                     Request info:\n\
                     %s"
                     !alarm_notice_period
                     (worker_info w)
                with _ -> return ()
                end)))
  in
    Lwt_preemptive.run_in_main (fun () -> Lwt_timeout.start timeout; return ());
    begin try
      Curl.perform w.handle;
    with exn ->
      Lwt_preemptive.run_in_main
        (fun () -> Lwt_log.debug_f ~section ~exn "Curl.perform exception");
      exn_r := Some exn
    end;
    Lwt_preemptive.run_in_main (fun () -> Lwt_timeout.stop timeout; return ());
    if !thread_count > !max_threads then w.reuse <- false;
    Lwt_unix.send_notification id;
    if !thread_count <= !max_threads then worker_loop w

let make_worker () =
  incr thread_count;
  let w =
    {
      thread = Thread.self ();
      handle = Curl.init ();
      start_task_channel = Event.new_channel ();
      reuse = true;
      response_header = None;
    }
  in w.thread <- Thread.create worker_loop w;
     Gc.finalise (fun w -> Curl.cleanup w.handle) w;
     w

let add_worker worker =
  match Lwt_sequence.take_opt_l waiters with
      None -> Queue.add worker workers
    | Some w -> wakeup w worker

let get_worker () =
  if not (Queue.is_empty workers) then
    return (Queue.take workers)
  else if !thread_count < !max_threads then
    return (make_worker ())
  else begin
    let (res, w) = Lwt.task () in
    let node = Lwt_sequence.add_r w waiters in
    Lwt.on_cancel res (fun _ -> Lwt_sequence.remove node);
    res
  end

let wrap_curl_perform_aux setup =
  let timeout =
    Lwt_timeout.create 5
      (fun () ->
         ignore
           begin try_lwt
             Lwt_log.warning_f ~section "Could not get Curl worker in 5s."
           with _ -> return ()
           end) in
  let () = Lwt_timeout.start timeout in
  lwt w  = get_worker () in
  let () = Lwt_timeout.stop timeout in
  let waiter, wakener = Lwt.wait () in
  let exn_r = ref None in
  let id =
    Lwt_unix.make_notification ~once:true
      (fun () -> match !exn_r with
           None -> Lwt.wakeup wakener ()
         | Some e -> Lwt.wakeup_exn wakener e) in
  let out = setup w w.handle waiter in
    ignore
      begin try_lwt
        waiter
      with _ ->
          (* ignore exn from waiter, don't want it to be raised at some
           * random point in the program; threads waiting on waiter (channel
           * reader, header grabber) will get it anyway *)
        return ()
      finally
        (* add to pool if can reuse *)
        if w.reuse then
          add_worker w
        else begin
          (* free associated resources *)
          decr thread_count;
          Thread.join w.thread;
        end;
        return ()
      end;
    send_event_block w.start_task_channel (id, exn_r);
    return out

let setup_output_chan ?buffer_size handle wait_perform_finish =
  let wait_awaken  = ref (Lwt.task ()) in
  let data_written = Event.new_channel () in
  let closed       = ref false in
  let buffer       = ref "" in
  let offset       = ref 0 in
  let unregistered = ref false in

  let data         = ref "" in
  let have_data    =
    Lwt_unix.make_notification (fun () -> Lwt.wakeup (snd !wait_awaken) !data) in

  let close () =
    (* We try to awaken the writefunction so that it knows that the transfer
     * is to be aborted. *)
    (* We use try_send_event because the write function might not be waiting
     * for the event at this point, since:
     * * the transfer could already be finished
     * * data have been consumed from the channel right before the close op,
     *   resulting in an event being sent before we send ours here *)
    (* The worker thread could be stuck in the writefunction if the
     * read operation is aborted (i.e., fst !wait_awaken is canceled)
     * and try_send_event is executed before the corresponding
     * recv_event. So we try to signal that the curl request is to be
     * canceled for up to 5s, hoping that [recv_event data_written]
     * will have run by then.  *)
    closed := true;
    ignore begin
      try_lwt
        for_lwt i = 1 to 10 do
          return (try_send_event data_written 0) >>
          Lwt_unix.sleep 0.5
        done >>
        if !unregistered then return ()
        else begin
          unregistered := true;
          return (Lwt_unix.stop_notification have_data)
        end
      with _ -> return ()
    end;
    return ()
  in

  let ch =
    Lwt_io.make
      ?buffer:(match buffer_size with None -> None | Some n -> Some (Lwt_bytes.create n))
      ~mode:Lwt_io.input ~close
      (fun buf off wanted ->
         let avail = String.length !buffer - !offset in
           if avail > 0 then begin
             (* can read from buffer *)
             let n = min avail wanted in
               Lwt_bytes.blit_from_bytes !buffer !offset buf off n;
               offset := !offset + n;
               return n
           end else if !closed then return 0
           else begin
             (* must read new data *)
             lwt data = fst !wait_awaken in
             let len = String.length data in
               if len = 0 then
                 return 0
               else begin
                 let avail = String.length data in
                 let n = min wanted avail in
                   Lwt_bytes.blit_from_bytes data 0 buf off n;
                   buffer := data;
                   offset := n;
                   wait_awaken := Lwt.task ();
                   (* We cannot use try_send_event here because otherwise we
                    * could send it before recv_event is run in the other
                    * thread, and the event would be lost. It's safe to use
                    * send_event_block here, because wait_awaken will only
                    * return non-empty data when signalled by the worker
                    * thread right before it runs recv_event. *)
                   send_event_block data_written avail;
                   return n
               end
           end)
  in
    ignore begin
      try_lwt
        lwt _ = wait_perform_finish in
          (try Lwt.wakeup (snd !wait_awaken) "" with _ -> ());
          return ()
      with e ->
        (try Lwt.wakeup_exn (snd !wait_awaken) e with _ -> ());
        return ()
      finally
        close ()
    end;
    Curl.set_writefunction handle
      (fun buf ->
         (* if the channel is closed before all the data is written by Curl,
          * return 0 and Curl will cancel the transfer and signal
          * CURLE_WRITE_ERROR to threads waiting for wait_perform_finish *)
         if !closed then 0
         else begin
           data := buf;
           Lwt_unix.send_notification have_data;
           (* we check right before recv_event so that the probability of
            * the thread preempting between the checking !closed and
            * the recv_event is smaller, thus allowing the worker to finish
            * faster on average, by letting the first try_send_event succeed.
            * *)
           if not !closed then recv_event data_written else 0
         end);
    ch

let status_re =
  Pcre.regexp "^([^ \t]+)[ \t]+(\\d+)([ \t]+([^\r\n]*))?\r?\n"

let setup_header_reader ~redirect worker handle wait_perform_finish =
  worker.response_header <- None;
  let header      = Buffer.create 13 in
  let data        = ref "" in
  let wait_awaken = ref (Lwt.task ()) in
  let have_header =
    Lwt_unix.make_notification ~once:true
      (fun () -> Lwt.wakeup (snd !wait_awaken) !data) in
  let canceled    = ref false in
    ignore begin
      try_lwt
        lwt _ = wait_perform_finish in
          return ()
          (* FIXME: cancel waiter if no header obtained even if the request
          * completes OK (shouldn't happen) *)
      with e ->
        (try Lwt.wakeup_exn (snd !wait_awaken) e with _ -> ());
        return ()
    end;
    Lwt.on_cancel (fst !wait_awaken) (fun () -> canceled := true);
    Curl.set_headerfunction handle
      (fun s ->
          (* "The callback function must return the number of bytes
           * actually taken care of, or return -1 to signal error
           * to  the  library  (it  will cause it to abort the transfer
           * with a CURLE_WRITE_ERROR return code)." *)
         if !canceled then -1
         else begin
           Buffer.add_string header s;
           if not (Pcre.pmatch ~pat:"\\S" s) then begin
             let whole_header = Buffer.contents header in
               begin try
                 let captures = Pcre.extract ~rex:status_re whole_header in
                 let code = int_of_string captures.(2) in
                   (* drop 1xx *)
                   if code >= 100 && code < 200 ||
                      (* if [redirect], we drop the initial 301-303/307
                       * response *)
                      redirect && (code >= 301 && code <= 303 || code = 307) then
                     Buffer.clear header
                   else begin
                     data := whole_header;
                     worker.response_header <- Some whole_header;
                     Lwt_unix.send_notification have_header;
                   end
               with _ -> () end;
           end;
           String.length s
         end);
    fst !wait_awaken

let wrap_curl_perform_ro ~redirect ?buffer_size setup =
  wrap_curl_perform_aux
    (fun worker handle wait_perform_finish ->
       setup handle wait_perform_finish;
       let ich = setup_output_chan ?buffer_size handle wait_perform_finish in
       let header = setup_header_reader ~redirect worker handle wait_perform_finish in
         (header, ich))

let set_req_options options t _ =
  let open Curl in
  reset t;
  List.iter (setopt t) (CURLOPT_NOSIGNAL true :: options)


(**************************************************************************)
(**************************************************************************)
(*************************  code taken from ocamlnet **********************)
(**************************************************************************)
(**************************************************************************)

(* The following code carries these license terms:

    Copyright (c) 2001-2006 Patrick Doane and Gerd Stolpmann

    This software is provided 'as-is', without any express or implied
    warranty. In no event will the authors be held liable for any damages
    arising from the use of this software.

    Permission is granted to anyone to use this software for any purpose,
    including commercial applications, and to alter it and redistribute it
    freely, subject to the following restrictions:

    1. The origin of this software must not be misrepresented; you must
    not claim that you wrote the original software. If you use this
    software in a product, an acknowledgment in the product documentation
    would be appreciated but is not required.

    2. Altered source versions must be plainly marked as such, and must
    not be misrepresented as being the original software.

    3. This notice may not be removed or altered from any source
    distribution.
*)

module HTTP_header :
sig
  val scan_header :
    ?downcase:bool ->              (* default: true *)
    ?unfold:bool ->                (* default: true *)
    ?strip:bool ->                 (* default: false *)
    string -> start_pos:int -> end_pos:int ->
    ((string * string) list * int)
end =
struct
  let rec find_line_start s pos len =
    if len > 0 then
      match s.[pos] with
        | '\010' ->
            pos+1
        | '\013' ->
            if len > 1 && s.[pos+1] = '\010' then
              pos+2
            else
              find_line_start s (pos+1) (len-1)
        | _ ->
            find_line_start s (pos+1) (len-1)
    else
      raise Not_found


  let rec find_line_end s pos len =
    if len > 0 then
      match s.[pos] with
        | '\010' ->
            pos
        | '\013' ->
            if len > 1 && s.[pos+1] = '\010' then
              pos
            else
              find_line_end s (pos+1) (len-1)
        | _ ->
            find_line_end s (pos+1) (len-1)
    else
      raise Not_found


  let rec find_double_line_start s pos len =
    let pos' = find_line_start s pos len in
    let len' = len - (pos' - pos) in
    if len' > 0 then
      match s.[pos'] with
        | '\010' ->
            pos'+1
        | '\013' ->
            if len' > 1 && s.[pos'+1] = '\010' then
              pos'+2
            else
              find_double_line_start s pos' len'
        | _ ->
            find_double_line_start s pos' len'
    else
      raise Not_found


  let fold_lines_p f acc0 s pos len =
    let e = pos+len in
    let rec loop acc p =
      if p < e then (
        let p1 =
          try find_line_end s p (e-p)
          with Not_found -> e in
        let p2 =
          try find_line_start s p1 (e-p1)
          with Not_found -> e in
        let is_last =
          p2 = e in
        let acc' =
          f acc p p1 p2 is_last in
        loop acc' p2
      )
      else acc in
    loop acc0 pos


  let skip_whitespace_left s pos len =
    let e = pos+len in
    let rec skip_whitespace p =
      if p < e then (
        let c = s.[p] in
        match c with
          | ' ' | '\t' | '\r' | '\n' -> skip_whitespace(p+1)
          | _ -> p
      )
      else
        raise Not_found in
    skip_whitespace pos


  let skip_whitespace_right s pos len =
    let rec skip_whitespace p =
      if p >= pos then (
        let c = s.[p] in
        match c with
          | ' ' | '\t' | '\r' | '\n' -> skip_whitespace(p-1)
          | _ -> p
      )
      else
        raise Not_found in
    skip_whitespace (pos+len-1)


  type header_line =
    | Header_start of string * string   (* name, value *)
    | Header_cont of string             (* continued value *)
    | Header_end                        (* empty line = header end *)


  let rec find_colon s p e =
    if p < e then (
      let c = s.[p] in
      match c with
        | ' ' | '\t' | '\r' | '\n' -> raise Not_found
        | ':' -> p
        | _ -> find_colon s (p+1) e
    )
    else raise Not_found


  let parse_header_line include_eol skip_ws s p0 p1 p2 is_last =
    (* p0: start of line
       p1: position of line terminator
       p2: position after line terminator
       is_last: whether last line in the iteration
       include_eol: whether to include the line terminator in the output string
       skip_ws: whether to skip whitespace after the ":"

       Raises Not_found if not parsable.
     *)
    if p0 = p1 then (
      if not is_last then raise Not_found;
      Header_end
    ) else (
      let c0 = s.[p0] in
      let is_cont = (c0 = ' ' || c0 = '\t' || c0 = '\r') in
      if is_cont then (
        let out =
          if include_eol then
            String.sub s p0 (p2-p0)
          else
            String.sub s p0 (p1-p0) in
        Header_cont out
      )
      else (
        let q = find_colon s p0 p1 in
        let r =
          if skip_ws then
            try skip_whitespace_left s (q+1) (p1-q-1) with Not_found -> p1
          else
            q+1 in
        let out_name = String.sub s p0 (q-p0) in
        let out_value =
          if include_eol then
            String.sub s r (p2-r)
          else
            String.sub s r (p1-r) in
        Header_start(out_name,out_value)
      )
    )


  let fold_header ?(downcase=false) ?(unfold=false) ?(strip=false)
                  f acc0 s pos len =
    let err k =
      failwith ("Netmime_string.fold_header [" ^ string_of_int k ^ "]") in
    let postprocess cur =
      match cur with
        | None ->
            None
        | Some(n, values) ->
            let cat_values1 =
              String.concat "" (List.rev values) in
            let cat_values2 =
              if strip then
                try
                  let k =
                    skip_whitespace_right
                      cat_values1 0 (String.length cat_values1) in
                  String.sub cat_values1 0 (k+1)
                with Not_found -> cat_values1
              else
                cat_values1 in
            let n' =
              if downcase then String.lowercase n else n in
            Some(n', cat_values2) in
    let (user, cur, at_end) =
      fold_lines_p
        (fun (acc_user, acc_cur, acc_end) p0 p1 p2 is_last ->
           if acc_end then err 1;
           let hd =
             try
               parse_header_line
                 (not unfold) strip s p0 p1 p2 is_last
             with Not_found -> err 2 in
           match hd with
             | Header_start(n,v) ->
                 let last_header_opt = postprocess acc_cur in
                 let acc_cur' = Some(n, [v]) in
                 let acc_user' =
                   match last_header_opt with
                     | None -> acc_user
                     | Some(n,v) -> f acc_user n v in
                 (acc_user', acc_cur', false)
             | Header_cont v ->
                 ( match acc_cur with
                     | None -> err 3
                     | Some(n, values) ->
                         let acc_cur' = Some (n, (v::values)) in
                         (acc_user, acc_cur', false)
                 )
             | Header_end ->
                 let last_header_opt = postprocess acc_cur in
                 let acc_user' =
                   match last_header_opt with
                     | None -> acc_user
                     | Some(n,v) -> f acc_user n v in
                 (acc_user', None, true)
        )
        (acc0, None, false)
        s pos len in
    if not at_end then err 4;
    assert(cur = None);
    user


  let list_header ?downcase ?unfold ?strip s pos len =
    List.rev
      (fold_header
         ?downcase ?unfold ?strip
         (fun acc n v -> (n,v) :: acc)
         [] s pos len
      )


  let find_end_of_header s pos len =
    (* Returns the position after the header, or raises Not_found *)
    if len > 0 && s.[pos]='\n' then
      pos+1
    else
      if len > 1 && s.[pos]='\r' && s.[pos+1]='\n' then
        pos+2
      else
        find_double_line_start s pos len


  let scan_header ?(downcase=true)
                  ?(unfold=true)
                  ?(strip=false)
                  parstr ~start_pos ~end_pos =
    try
      let real_end_pos =
        find_end_of_header parstr start_pos (end_pos-start_pos) in
      let values =
        list_header
          ~downcase ~unfold ~strip:(unfold || strip) parstr
          start_pos (real_end_pos - start_pos) in
      (values, real_end_pos)
    with
      | Not_found | Failure _ ->
          failwith "Netmime_string.scan_header"
end

module CI : sig  (* case-insensitive strings *)
  type t
  val compare : t -> t -> int
  val make : string -> t
end = struct
  type t = string
  let compare (a_ci:t) (b_ci:t) =
    Pervasives.compare a_ci b_ci
  let make s = String.lowercase s
end

module CIMap = Map.Make(CI)
  (* Maps from case-insensitive strings to any type *)

(**************************************************************************)
(**************************************************************************)
(*************************  end of ocamlnet code     **********************)
(**************************************************************************)
(**************************************************************************)

class mime_header_ro fields =
object
  val map = lazy begin
              List.fold_left
                (fun m (k, v) ->
                   let k = CI.make k in
                   let l = try CIMap.find k m with Not_found -> [] in
                     CIMap.add k (v :: l) m)
                CIMap.empty fields
            end

  method fields           = fields
  method field k : string = List.hd (List.rev (CIMap.find (CI.make k) (Lazy.force map)))
  method multiple_field k = List.rev (CIMap.find (CI.make k) (Lazy.force map))
end

let http_request ~redirect ?(options = []) set_opts uri =
  let options           = Curl.CURLOPT_URL uri :: options in
  (* wrap_curl_perform_ro returns when we have a worker *)
  lwt (header_txt, ich) = wrap_curl_perform_ro ~redirect (set_opts options) in
  let ()                =
   Lwt.on_cancel header_txt
     (fun () -> ignore (try_lwt Lwt_io.close ich with _ -> return ())) in
  lwt header_txt        =
    (* if there's a problem while reading the header, close the input
     * channel (so that Curl.perform completes) *)
    try_lwt header_txt
    with e ->
      Lwt_io.close ich >>
      raise_lwt e in
  let captures    = Pcre.extract ~rex:status_re header_txt in
  let code        = int_of_string captures.(2) in
  let header_l, _ = HTTP_header.scan_header
                      ~downcase:false ~unfold:true ~strip:true
                      ~start_pos:(String.length captures.(0))
                      ~end_pos:(String.length header_txt)
                      header_txt in
  let header = new mime_header_ro header_l in
    return (code, header, ich)

let simple_http_request ~redirect ?options uri =
  http_request ~redirect ?options set_req_options uri

let get ?(redirect=true) ?(options = []) uri =
  let open Curl in
  let options = CURLOPT_NOBODY false :: CURLOPT_HTTPGET true ::
                CURLOPT_FOLLOWLOCATION redirect :: options in
    simple_http_request ~redirect ~options uri

let head ?(redirect=true) ?(options = []) uri =
  let open Curl in
  let options = CURLOPT_NOBODY true :: CURLOPT_HTTPGET true ::
                CURLOPT_FOLLOWLOCATION redirect :: options in
  lwt code, header, ich = simple_http_request ~redirect ~options uri in
    return (code, header)

let put ?(redirect=true) ?(options = []) source uri =

  lwt read_data, size, close =
    match source with
        `Memory s ->
          let offset = ref 0 in
          let len    = String.length s in

          let close () = return () in

          let read wanted =
            let n = min (len - !offset) wanted in
            let ret = String.sub s !offset n in
              offset := !offset + n;
              ret
          in
            return (read, Some (Int64.of_int (String.length s)), close)

      | `Channel (ic, len) ->
         let close () = Lwt_io.close ic in

         let read wanted =
           Lwt_preemptive.run_in_main
             (fun () -> Lwt_io.read ~count:wanted ic)
         in
           return (read, len, close)

      | `File s ->
          lwt ic  = Lwt_io.open_file ~mode:Lwt_io.input s in
          lwt len = Lwt_io.length ic in

          let close () = Lwt_io.close ic in

          let read wanted =
            Lwt_preemptive.run_in_main
              (fun () -> Lwt_io.read ~count:wanted ic)
          in
            return (read, Some len, close) in
  let options =
    Curl.CURLOPT_FOLLOWLOCATION redirect ::
    Curl.CURLOPT_UPLOAD true ::
    Curl.CURLOPT_READFUNCTION read_data ::
    options in
  let options =
    match size with
        None -> options
      | Some size -> Curl.CURLOPT_INFILESIZELARGE size :: options
  in
    http_request ~redirect ~options
      (fun options t wait_finish ->
         set_req_options options t wait_finish;
         ignore begin
           try_lwt
             wait_finish
           finally
             close ()
         end)
      uri

let post_raw_data ?(redirect=true) ?(options = []) ~data uri =
  let options =
    Curl.CURLOPT_POST true ::
    Curl.CURLOPT_POSTFIELDS data ::
    Curl.CURLOPT_POSTFIELDSIZE (String.length data) ::
    options
  in
    simple_http_request ~redirect ~options uri

let post_multipart ?(redirect=true) ?(options = []) parts uri =
  let options = Curl.CURLOPT_HTTPPOST parts :: options in
    simple_http_request ~redirect ~options uri
