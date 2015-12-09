(** Non-blocking Curl usage in the Lwt monad. *)

(** [Curl_lwt] maintains a pool of Curl workers that service requests in
  * separate threads so as to avoid blocking.
  *
  * Exceptions in the worker (normally raised by Curl) are caught and
  * re-thrown in the main (Lwt) thread that called the function.
  * *)




(** {2 Simplified interface for HTTP(S) requests } *)

(** Order-preserving, case-insensitive HTTP field map. *)
class type mime_header_ro =
object

  (** return complete header *)
  method fields : (string * string) list

  (** Return first header value or raises [Not_found] *)
  method field  : string -> string

  (** Return all fields with the same name. *)
  method multiple_field : string -> string list

  method content_length : unit -> int
end

(** [get ~redirect ?options uri] initializes a Curl worker with
  * the specified [options] and performs the request, returning the response
  * code, the parsed response header and the returned data as an input channel.
  * If [redirect] is true, [CURLOPT_FOLLOWLOCATION true] is automatically
  * prepended to the options, and the 301-303/307 responses are dropped, so
  * that the returned code and header correspond to the last attempt, after
  * redirection.
  *
  * Note that the returned channel must be closed to ensure the Curl request
  * is finalized and the worker is released. *)
val get :
  ?redirect:bool -> ?options:Curl.curlOption list ->
  string -> (int * mime_header_ro * Lwt_io.input Lwt_io.channel) Lwt.t

(** Perform an HTTP(S) HEAD. Refer to {!get}. *)
val head :
  ?redirect:bool ->
  ?options:Curl.curlOption list -> string -> (int * mime_header_ro) Lwt.t

(** Perform an HTTP(S) PUT, with the provided data. Refer to {!get}.
  * The data to be PUT is either a string ([`Memory s]), held in a file
  * ([`File filename]) or a channel ([`Channel (ic, length)]).
  * *)
val put :
  ?redirect:bool -> ?options:Curl.curlOption list ->
  [< `Channel of Lwt_io.input_channel * int64 option
   | `File of Lwt_io.file_name
   | `Memory of string ] ->
  string ->
  (int * mime_header_ro * Lwt_io.input Lwt_io.channel) Lwt.t

(** Perform an HTTP(S) POST, with the data provided in [~data], which is assumed
  * to be urlencoded. The content-type is automatically set to
  * ["application/x-www-form-urlencoded"]; override this with
  * [CURL_HTTPHEADER] if needed. Refer to {!get}. *)
val post_raw_data :
  ?redirect:bool -> ?options:Curl.curlOption list ->
  data:string -> string ->
  (int * mime_header_ro * Lwt_io.input Lwt_io.channel) Lwt.t

(** Perform a multipart HTTP(S) POST. Refer to {!get}. *)
val post_multipart :
  ?redirect:bool -> ?options:Curl.curlOption list ->
  Curl.curlHTTPPost list -> string ->
  (int * mime_header_ro * Lwt_io.input Lwt_io.channel) Lwt.t

(** {2 Generic interface} *)

(** [simple_http_request ~redirect ?options uri] initializes a Curl worker with
  * the specified [options] and performs the request, returning the response
  * code, the parsed response header and the returned data as an input channel.
  * If [redirect] is true, [CURLOPT_FOLLOWLOCATION true] is automatically
  * prepended to the options, and the 301-303/307 responses are dropped, so
  * that the returned code and header correspond to the last attempt, after
  * redirection.
  *
  * Note that the returned channel must be closed to ensure the Curl request
  * is finalized and the worker is released. *)
val simple_http_request :
  redirect:bool -> ?options:Curl.curlOption list ->
  string -> (int * mime_header_ro * Lwt_io.input Lwt_io.channel) Lwt.t

(** [http_request ~redirect ?options setup uri] is analogous to
  * [simple_http_request ~redirect ?options uri],
  * but allows to control the initialization of the [Curl.t] handler with the
  * [setup] function. [setup] is given the actual option list (which might defer
  * a bit from the supplied [options], e.g. by adding [Curl.CURLOPT_URL]),
  * the [Curl.t] handle, and a [unit Lwt.t] value that will return/raise when
  * the request is considered complete by [Curl] (it can be used, for
  * instance, to close an input channel).
  * *)
val http_request :
  redirect:bool -> ?options:Curl.curlOption list ->
  (Curl.curlOption list -> Curl.t -> unit Lwt.t -> unit) ->
  string -> (int * mime_header_ro * Lwt_io.input Lwt_io.channel) Lwt.t

(** {2 Internal machinery} *)
(** Section used for Curl_lwt-generated logs. *)
val section : Lwt_log.section

(** Curl_lwt will log a notice in the above {!section} if a request takes
  * longer than the period in seconds returned by [get_alarm_notice_period].
  * (default: 60).
  * *)
val get_alarm_notice_period : unit -> int

(** Set the period of the timeout notice alarm. *)
val set_alarm_notice_period : int -> unit

(** Return the maximum number of threads that will be active servicing
  * requests at a time. (Default: 20) *)
val get_max_threads : unit -> int

(** Set the maximum number of threads to use to service concurrent requests.
  * If lower than the current number of active threads, the workers will be
  * removed from the pool when they complete their current requests. *)
val set_max_threads : int -> unit

(** Returns how many threads have been spawn, some or all of which might be
  * free, waiting for requests. *)
val get_current_threads : unit -> int

(** Returns how many requests can be started concurrently at this point
  * without any of them having to wait before it gets a worker to service it. *)
val get_free_workers : unit -> int
