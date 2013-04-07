open Printf
open Lwt

let () =
  Lwt_unix.run begin
    lwt code, header, ch =
      Curl_lwt.get "http://programming.reddit.com"
    in
      printf "Got %d response\n" code;
      print_endline (String.make 78 '=');
      lwt s = Lwt_io.read ch in
        printf "%d bytes\n" (String.length s);
        return ()
  end
