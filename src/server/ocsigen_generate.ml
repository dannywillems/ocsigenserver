open Lwt
open Cohttp

open Ocsigen_lib
open Ocsigen_http_frame
open Ocsigen_headers
open Ocsigen_http_com
open Ocsigen_socket
open Ocsigen_cookies
open Ocsigen_request_info

exception Ocsigen_upload_forbidden

type to_write =
    No_File of string * Buffer.t
  | A_File of (string * string * string * Unix.file_descr
               * ((string * string) * (string * string) list) option)

let get_boundary ctparams = List.assoc "boundary" ctparams
let counter = let c = ref (Random.int 1000000) in fun () -> c := !c + 1 ; !c

let find_field field content_disp =
  let (_, res) = Netstring_pcre.search_forward
      (Netstring_pcre.regexp (field^"=.([^\"]*).;?")) content_disp 0 in
  Netstring_pcre.matched_group res 1 content_disp

let rec find_post_params http_frame ct filenames =
  match http_frame.Ocsigen_http_frame.frame_content with
  | None -> None
  | Some body_gen ->
    let ((ct, cst), ctparams) = match ct with
      (* RFC 2616, sect. 7.2.1 *)
      (* If the media type remains unknown, the recipient SHOULD
         treat it as type "application/octet-stream". *)
      | None -> (("application", "octet-stream"), [])
      | Some (c, p) -> (c, p)
    in
    match String.lowercase ct, String.lowercase cst with
    | "application", "x-www-form-urlencoded" ->
      Some (find_post_params_form_urlencoded body_gen)
    | "multipart", "form-data" ->
      Some (find_post_params_multipart_form_data
              body_gen ctparams filenames)
    | _ -> None

and find_post_params_form_urlencoded body_gen _ =
  Lwt.catch
    (fun () ->
       let body = Ocsigen_stream.get body_gen in
       (* BY, adapted from a previous comment. Should this stream be
          consumed in case of error? *)
       Ocsigen_stream.string_of_stream
         (Ocsigen_config.get_maxrequestbodysizeinmemory ())
         body >>= fun r ->
       let r = Url.fixup_url_string r in
       Lwt.return ((Netencoding.Url.dest_url_encoded_parameters r), [])
    )
    (function
      | Ocsigen_stream.String_too_large -> Lwt.fail Input_is_too_large
      | e -> Lwt.fail e)

and find_post_params_multipart_form_data body_gen ctparams filenames
    (uploaddir, maxuploadfilesize)=
  (* Same question here, should this stream be consumed after an error ? *)
  let body = Ocsigen_stream.get body_gen
  and bound = get_boundary ctparams
  and params = ref []
  and files = ref [] in
  let create hs =
    let content_type =
      try
        let ct = List.assoc "content-type" hs in
        Ocsigen_headers.parse_content_type (Some ct)
      with _ -> None
    in
    let cd = List.assoc "content-disposition" hs in
    let p_name = find_field "name" cd in
    try
      let store = find_field "filename" cd in
      match uploaddir with
      | Some dname ->
        let now = Printf.sprintf "%f-%d"
            (Unix.gettimeofday ()) (counter ()) in
        let fname = dname^"/"^now in
        let fd = Unix.openfile fname
            [Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY; Unix.O_NONBLOCK] 0o666
        in
        Ocsigen_messages.debug2 ("Upload file opened: " ^ fname);
        filenames := fname::!filenames;
        A_File (p_name, fname, store, fd, content_type)
      | None -> raise Ocsigen_upload_forbidden
    with Not_found -> No_File (p_name, Buffer.create 1024)
  in
  let rec add where s =
    match where with
    | No_File (p_name, to_buf) ->
      Buffer.add_string to_buf s;
      Lwt.return ()
    | A_File (_,_,_,wh,_) ->
      let len = String.length s in
      let r = Unix.write wh s 0 len in
      if r < len then
        (*XXXX Inefficient if s is long *)
        add where (String.sub s r (len - r))
      else
        Lwt_unix.yield ()
  in
  let stop size = function
    | No_File (p_name, to_buf) ->
      Lwt.return
        (params := !params @ [(p_name, Buffer.contents to_buf)])
    (* a la fin ? *)
    | A_File (p_name,fname,oname,wh, content_type) ->
      (* Ocsigen_messages.debug "closing file"; *)
      files :=
        !files@[(p_name, {tmp_filename=fname;
                          filesize=size;
                          raw_original_filename=oname;
                          original_basename=(Filename.basename oname);
                          file_content_type = content_type;
                         })];
      Unix.close wh;
      Lwt.return ()
  in
  Multipart.scan_multipart_body_from_stream
    body bound create add stop maxuploadfilesize >>= fun () ->
  (*VVV Does scan_multipart_body_from_stream read until the end or
    only what it needs?  If we do not consume here, the following
    request will be read only when this one is finished ...  *)
  Ocsigen_stream.consume body_gen >>= fun () ->
  Lwt.return (!params, !files)

let of_cohttp_request ~address ~port filenames socket request body =

  let sockaddr = Unix.ADDR_INET (Unix.inet_addr_of_string "0.0.0.0", 0) in
  let client_inet_addr = ip_of_sockaddr sockaddr in
  let ipstring = Unix.string_of_inet_addr client_inet_addr in

  let meth =
    Ocsigen_http_frame.Http_header.meth_of_cohttp_meth @@
    Request.meth request
  in
  let clientproto =
    Ocsigen_http_frame.Http_header.proto_of_cohttp_version @@
    Request.version request
  in
  let url = Uri.to_string @@ Request.uri request in
  let http_frame =
    Ocsigen_http_frame.of_cohttp_request request body
  in
  let (_, headerhost, headerport, url, path, params, get_params) =
    Url.parse url in
  let headerhost, headerport =
    match headerhost with
    | None -> get_host_from_host_header http_frame
    | _ -> headerhost, headerport
  in
  if clientproto = Ocsigen_http_frame.Http_header.HTTP11 && headerhost = None
  then raise Ocsigen_Bad_Request;

  let useragent = get_user_agent http_frame in
  let cookies_string = lazy (get_cookie_string http_frame) in
  let cookies = lazy (match (Lazy.force cookies_string) with
      | None -> CookiesTable.empty
      | Some s -> parse_cookies s) in
  let ifmodifiedsince = get_if_modified_since http_frame in
  let ifunmodifiedsince = get_if_unmodified_since http_frame in
  let ifnonematch = get_if_none_match http_frame in
  let ifmatch = get_if_match http_frame in

  let ct_string = get_content_type http_frame in
  let ct = Ocsigen_headers.parse_content_type ct_string in
  let cl = get_content_length http_frame in

  let referer = lazy (get_referer http_frame) in
  let origin = lazy (get_origin http_frame) in

  let access_control_request_method =
    lazy (get_access_control_request_method http_frame) in
  let access_control_request_headers =
    lazy (get_access_control_request_headers http_frame) in

  let accept = lazy (get_accept http_frame) in
  let accept_charset = lazy (get_accept_charset http_frame) in
  let accept_encoding = lazy (get_accept_encoding http_frame) in
  let accept_language = lazy (get_accept_language http_frame) in

  let post_params0 =
    match meth with
    | Http_header.GET
    | Http_header.DELETE
    | Http_header.PUT
    | Http_header.HEAD -> None
    | Http_header.POST
    | Http_header.OPTIONS ->
      begin
        match find_post_params http_frame ct filenames with
        | None -> None
        | Some f ->
          let r = ref None in
          Some (fun ci -> match !r with
              | None -> let res = f ci in r := Some res; res
              | Some r -> r)
      end
    | _ -> failwith "of_cohttp_request: HTTP method not implemented"
  in

  let post_params =
    match post_params0 with
    | None -> None
    | Some f -> Some (fun ci -> f ci >>= fun (a, _) -> Lwt.return a)
  in
  let files =
    match post_params0 with
    | None -> None
    | Some f -> Some (fun ci -> f ci >>= fun (_, b) -> Lwt.return b)
  in

  let path_string = Url.string_of_url_path ~encode:true path in
  let dummy_receiver = Ocsigen_http_com.dummy_receiver () in

  Lwt.return
    {
      ri_url_string = url;
      ri_method = meth;
      ri_protocol = http_frame.Ocsigen_http_frame.frame_header.Ocsigen_http_frame.Http_header.proto;
      ri_ssl = false;
      ri_full_path_string = path_string;
      ri_full_path = path;
      ri_original_full_path_string = path_string;
      ri_original_full_path = path;
      ri_sub_path = path;
      ri_sub_path_string = Url.string_of_url_path ~encode:true path;
      ri_get_params_string = params;
      ri_host = headerhost;
      ri_port_from_host_field = headerport;
      ri_get_params = get_params;
      ri_initial_get_params = get_params;
      ri_post_params = post_params;
      ri_files = files;
      ri_remote_inet_addr = client_inet_addr;
      ri_remote_ip = ipstring;
      ri_remote_ip_parsed = lazy (Ipaddr.of_string_exn ipstring);
      ri_remote_port = port_of_sockaddr sockaddr;
      ri_forward_ip = [];
      ri_server_port = port;
      ri_user_agent = useragent;
      ri_cookies_string = cookies_string;
      ri_cookies = cookies;
      ri_ifmodifiedsince = ifmodifiedsince;
      ri_ifunmodifiedsince = ifunmodifiedsince;
      ri_ifnonematch = ifnonematch;
      ri_ifmatch = ifmatch;
      ri_content_type = ct;
      ri_content_type_string = ct_string;
      ri_content_length = cl;
      ri_referer = referer;
      ri_origin = origin;
      ri_access_control_request_method = access_control_request_method;
      ri_access_control_request_headers = access_control_request_headers;
      ri_accept = accept;
      ri_accept_charset = accept_charset;
      ri_accept_encoding = accept_encoding;
      ri_accept_language = accept_language;
      ri_http_frame = http_frame; (* XXX: not tested ! *)
      ri_request_cache = Polytables.create ();
      ri_client = dummy_receiver; (* XXX: it's obsolete with Cohttp ! *)
      ri_range = lazy (Ocsigen_range.get_range http_frame);
      ri_timeofday = Unix.gettimeofday ();
      ri_nb_tries = 0;
      ri_connection_closed = Ocsigen_http_com.closed dummy_receiver;
    }