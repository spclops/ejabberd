%%%-------------------------------------------------------------------
-module(mod_filestore_node).

-behaviour(gen_server).

%% API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {host, my_jid, opts, basepath, transfers}).
% TODO: add per-transfer known_streamhosts
-record(transfer, {jid_sid, state, filename, filesize, streamhost, stream_pid, request_stanza}).

-include_lib("kernel/include/file.hrl").
-include("ejabberd.hrl").
-include("jlib.hrl").
-include("adhoc.hrl").

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {Node,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Host, Node, MyHost, Opts) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [Host, jlib:make_jid(Node, MyHost, ""), Opts], []),
    {Node, Pid}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, MyJID, Opts]) ->
    Basepath = "/tmp/" ++ jlib:jid_to_string(MyJID),
    file:make_dir(Basepath),

    process_flag(trap_exit, true),
    Transfers = ets:new(transfers, [set, {keypos, #transfer.jid_sid}]),
    {ok, #state{host = Host, basepath = Basepath, my_jid = MyJID, opts = Opts, transfers = Transfers}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({route, From, To, {xmlelement, "iq", _, _} = Packet}, State) ->
    IQ = jlib:iq_query_or_response_info(Packet),
    case catch process_iq1(From, IQ, State) of
	Result when is_record(Result, iq) ->
	    ejabberd_router:route(To, From, jlib:iq_to_xml(Result));
	{'EXIT', Reason} when IQ#iq.type =/= error ->
	    ?ERROR_MSG("Error when processing IQ stanza: ~p", [Reason]),
	    Err = jlib:make_error_reply(Packet, ?ERR_INTERNAL_SERVER_ERROR),
	    ejabberd_router:route(To, From, Err);
	_ ->
	    ok
    end,
    {noreply, State};

handle_cast({streamhost_connected, StreamPid, {JID, Host, Port}},
	    State = #state{my_jid = MyJID, transfers = Transfers}) ->
    case transfer_by_stream_pid(StreamPid, Transfers) of
	% Receiving stream
	Transfer = #transfer{state = receiver_connecting,
			     jid_sid = {From, SID},
			     request_stanza = IQ,
			     filename = FileName,
			     filesize = FileSize} ->
	    PortS = io_lib:format("~B", [Port]),
	    Reply = IQ#iq{type = result,
			  sub_el = [{xmlelement, "query",
				     [{"xmlns", ?NS_BYTESTREAMS},
				      {"mode", "tcp"},
				      {"sid", SID}],
				     [{xmlelement, "streamhost-used",
				       [{"jid", JID},
					{"host", Host},
					{"port", PortS}], []}
				     ]}]
			 },
	    ejabberd_router:route(MyJID, From, jlib:iq_to_xml(Reply)),
	    ets:insert(Transfers, Transfer#transfer{state = receiving,
						    request_stanza = undefined}),
	    file:make_dir(user_path(State, From)),
	    gen_fsm:send_event(StreamPid, {receive_file, file_path(State, From, FileName), FileSize});
	% Sending stream
	Transfer = #transfer{jid_sid = {From, SID},
			     state = sender_connecting,
			     streamhost = {StreamhostJID, _, _},
			     stream_pid = StreamPid} ->
	    Activation = #iq{id = randoms:get_string(),
			     type = set,
			     sub_el = [{xmlelement, "query",
					[{"xmlns", ?NS_BYTESTREAMS},
					 {"sid", SID}],
					[{xmlelement, "activate", [],
					  [{xmlcdata, jlib:jid_to_string(From)}]}
					]}]
			    },
	    ets:insert(Transfers, Transfer#transfer{state = activating, request_stanza = Activation}),
	    ejabberd_router:route(MyJID, jlib:string_to_jid(StreamhostJID), jlib:iq_to_xml(Activation));
	error ->
	    ignore
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason},
	    State = #state{my_jid = MyJID, transfers = Transfers}) ->
    ?DEBUG("EXIT from ~p: ~p",[Pid, Reason]),
    case transfer_by_stream_pid(Pid, Transfers) of
	Transfer = #transfer{jid_sid = {From, _}, request_stanza = IQ} ->
	    ?DEBUG("Transfer of ~p ended.", [Transfer#transfer.filename]),
	    ets:delete(Transfers, Transfer#transfer.jid_sid),
	    if
		is_record(IQ, iq) ->
		    Packet = jlib:iq_to_xml(IQ),
		    case Reason of
			cannot_connect ->
			    Err = jlib:make_error_reply(Packet, ?ERR_REMOTE_SERVER_NOT_FOUND);
			_ ->
			    Err = jlib:make_error_reply(Packet, ?ERR_INTERNAL_SERVER_ERROR)
		    end,
		    ejabberd_router:route(MyJID, From, Err);
		true ->
		    ok
	    end,
	    {noreply, State};
	error ->
	    {stop, exit, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%%------------------------
%%% IQ Processing
%%%------------------------

process_iq1(From,
	    #iq{type = Type, id = ID} = IQ,
	    #state{transfers = Transfers} = State)
  when Type == result; Type == error ->
    case transfers_by_streamhost_request_id(From, ID, Transfers) of
	% Streamhost activation
	[#transfer{state = activating,
		   stream_pid = StreamPid,
		   filename = FileName} = Transfer | _] ->
	    ets:insert(Transfers, Transfer#transfer{state = sending, request_stanza = undefined}),
	    gen_fsm:send_event(StreamPid, {send_file, FileName});
	_ ->
	    process_iq2(From, IQ, State)
    end;
process_iq1(From, IQ, State) ->
    process_iq2(From, IQ, State).

-define(IDENTITY(Category, Type, Name), {xmlelement, "identity",
					 [{"category", Category},
					  {"type", Type},
					  {"name", Name}], []}).
-define(FEATURE(Var), {xmlelement, "feature", [{"var", Var}], []}).
-define(ITEM(JID, Node, Name), {xmlelement, "item",
				[{"jid", case JID of
					     #jid{} -> jlib:jid_to_string(JID);
					     _ -> JID
					 end},
				 {"node", Node},
				 {"name", Name}], []}).

%% disco#info request
process_iq2(_, #iq{type = get, xmlns = ?NS_DISCO_INFO, sub_el = {xmlelement, "query", QueryAttrs, _}} = IQ, _) ->
    Node = xml:get_attr_s("node", QueryAttrs),
    Info = case Node of
	       "" ->
		   [
		    ?IDENTITY("store", "file", "File Storage"),
		    ?FEATURE(?NS_DISCO_INFO),
		    ?FEATURE(?NS_DISCO_ITEMS),
		    ?FEATURE(?NS_BYTESTREAMS),
		    ?FEATURE(?NS_STREAM_INITIATION),
		    ?FEATURE("presence"),
		    ?FEATURE(?NS_COMMANDS),
		    ?FEATURE(?NS_XDATA)
		   ];
	       ?NS_COMMANDS ->
		   [
		    ?IDENTITY("automation", "command-node", "File operations"),
		    ?FEATURE(?NS_COMMANDS),
		    ?FEATURE(?NS_XDATA)
		   ];
	       _ ->
		   []
	   end,
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query",
	    [{"xmlns", ?NS_DISCO_INFO},
	     {"node", Node}],
	    Info}]};

%% disco#items request
process_iq2(_, #iq{type = get, xmlns = ?NS_DISCO_ITEMS, sub_el = {xmlelement, "query", QueryAttrs, _}} = IQ, #state{my_jid = MyJID}) ->
    Node = xml:get_attr_s("node", QueryAttrs),
    Items = case Node of
		"" ->
		    [
		     ?ITEM(MyJID, ?NS_COMMANDS, "File operations")
		    ];
		?NS_COMMANDS ->
		    [
		     ?ITEM(MyJID, "browse", "Browse and retrieve files"),
		     ?ITEM(MyJID, "delete", "Delete files")
		    ];
		_ ->
		    []
	    end,
    IQ#iq{type = result, sub_el =
	  [{xmlelement, "query",
	    [{"xmlns", ?NS_DISCO_ITEMS},
	     {"node", Node}],
	    Items}]};

%% Command execution
process_iq2(From, #iq{type = set, xmlns = ?NS_COMMANDS, sub_el = SubEl} = IQ, State) ->
    case adhoc:parse_request(IQ) of
	{error, Err} ->
	    IQ#iq{type = error, sub_el = [SubEl, Err]};
	#adhoc_request{} = Req ->
	    #adhoc_response{} = Resp = process_adhoc(From, Req, State),
	    IQ#iq{type = result, sub_el = [adhoc:produce_response(Resp)]}
    end;

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Receiving iq handlers %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%

% TODO: range support

%% File-transfer offer
process_iq2(From,
	   #iq{type = set, xmlns = ?NS_STREAM_INITIATION, sub_el = {xmlelement, "si", SIAttrs, _} = SubEl} = IQ,
	   #state{transfers = Transfers}) ->
    SID = xml:get_attr_s("id", SIAttrs),
    %?NS_STREAM_INITIATION = xml:get_attr_s("xmlns", SIAttrs),
    ?PROFILE_FILE_TRANSFER = xml:get_attr_s("profile", SIAttrs),
    
    {xmlelement, "file", FileAttrs, _} = xml:get_subtag(SubEl, "file"),
    FileName = xml:get_attr_s("name", FileAttrs),
    FileSizeS = xml:get_attr_s("size", FileAttrs),
    {FileSize, ""} = string:to_integer(FileSizeS),
    
    StreamMethods = si_find_stream_methods(SubEl),
    true = lists:member(?NS_BYTESTREAMS, StreamMethods),
    
    ets:insert(Transfers, #transfer{jid_sid = {From, SID},
				    state = offer_received,
				    filename = FileName,
				    filesize = FileSize}),
    
    ?DEBUG("Accepted file ~p (~p Bytes) from ~p (~p)", [FileName, FileSize, From, SID]),
    IQ#iq{type = result, sub_el = [{xmlelement, "si",
				    [{"xmlns", ?NS_STREAM_INITIATION}],
				    [{xmlelement, "feature",
				      [{"xmlns", ?NS_FEATURE_NEG}],
				      [{xmlelement, "x",
					[{"xmlns", ?NS_XDATA},
					 {"type", "submit"}],
					[{xmlelement, "field",
					  [{"var", "stream-method"}],
					  [{xmlelement, "value",
					    [],
					    [{xmlcdata, ?NS_BYTESTREAMS}]}
					  ]}
					]}
				      ]}
				    ]}
				  ]};

%% Bytestreams initiation
process_iq2(From,
	   #iq{type = set, xmlns = ?NS_BYTESTREAMS, sub_el = {xmlelement, "query", QueryAttrs, QueryChildren} = SubEl} = IQ,
	   #state{my_jid = MyJID, transfers = Transfers}) ->
    SID = xml:get_attr_s("sid", QueryAttrs),
    ?DEBUG("Bytestreams initiation from ~p (~p)", [From,SID]),
    case ets:lookup(Transfers, {From, SID}) of
	[#transfer{state = offer_received} = Transfer] ->
	    case xml:get_attr_s("mode", QueryAttrs) of
		Mode when Mode == ""; Mode == "tcp" ->
		    StreamHosts = bytestreams_query_streamhosts(QueryChildren),
		    SHA1 = make_sockshost(SID, From, MyJID),
		    {ok, StreamPid} = mod_filestore_stream:start_link(self(), StreamHosts, SHA1),
		    ets:insert(Transfers, Transfer#transfer{state = receiver_connecting,
							    stream_pid = StreamPid,
							    request_stanza = IQ}),
		    ok;
		_ -> % Mode == "udp" or something else
		    ets:delete(Transfers, {From, SID}),
		    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ACCEPTABLE]}
	    end;
	[] ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_UNEXPECTED_REQUEST]}
    end;

%%%%%%%%%%%%%%%%%%%%%%%%%
%% Sending iq handlers %%
%%%%%%%%%%%%%%%%%%%%%%%%%

% TODO: range support

%% File-transfer accept
process_iq2(From,
	   #iq{type = result, id = ID, xmlns = ?NS_STREAM_INITIATION} = IQ,
	   #state{transfers = Transfers} = State) ->
    ?DEBUG("File-transfer accept: ~p",[IQ]),
    case transfers_by_jid_request_id(From, ID, Transfers) of
	[#transfer{state = offer_sent, jid_sid = {From, SID}} = Transfer | _] ->
	    IQ2 = #iq{id = randoms:get_string(),
		      type = set,
		      sub_el = [{xmlelement, "query",
				 [{"xmlns", ?NS_BYTESTREAMS},
				  {"sid", SID},
				  {"mode", "tcp"}],
				 lists:map(fun({StreamHostJID, Host, Port}) ->
						   {xmlelement, "streamhost",
						    [{"jid", StreamHostJID},
						     {"host", Host},
						     {"port", io_lib:format("~B", [Port])}], []}
					   end, mod_filestore_service:get_streamhosts(State#state.host))}]},
	    ets:insert(Transfers, Transfer#transfer{state = streamhosts_sent,
						    request_stanza = IQ2}),
	    IQ2;
	[] ->
	    IQ#iq{type = error, sub_el = [IQ#iq.sub_el, ?ERR_GONE]}
    end;

%% Bytestreams streamhost-used reply
process_iq2(From,
	   #iq{type = result, id = ID, xmlns = ?NS_BYTESTREAMS,
	       sub_el = [{xmlelement, "query", _, _} = SubEl | _]},
	   #state{my_jid = MyJID, transfers = Transfers} = State) ->
    ?DEBUG("Bytestreams reply: ~p", [SubEl]),
    case xml:get_subtag(SubEl, "streamhost-used") of
	{xmlelement, "streamhost-used", StreamhostUsedAttrs, _} ->
	    case transfers_by_jid_request_id(From, ID, Transfers) of
		[#transfer{jid_sid = {_, SID},
			   state = streamhosts_sent} = Transfer | _] ->
		    StreamhostJID = xml:get_attr_s("jid", StreamhostUsedAttrs),
		    Streamhost = {_, _, _} = mod_filestore_service:get_streamhost(State#state.host, StreamhostJID),
		    SHA1 = make_sockshost(SID, MyJID, From),
		    {ok, StreamPid} = mod_filestore_stream:start_link(self(), [Streamhost], SHA1),
		    ets:insert(Transfers, Transfer#transfer{state = sender_connecting,
							    streamhost = Streamhost,
							    stream_pid = StreamPid,
							    request_stanza = undefined});
		[] ->
		    ignore
	    end;
	_ ->
	    ignore
    end,
    ok;


%% Generic transfer refuse/error
process_iq2(From,
	   #iq{type = error, id = ID}, #state{transfers = Transfers}) ->
    Stale = transfers_by_jid_request_id(From, ID, Transfers),
    lists:foreach(fun(#transfer{jid_sid = JIDSID, stream_pid = StreamPid}) ->
			  if
			      is_pid(StreamPid) ->
				  % We will receive 'EXIT' then, no need to remove here
				  exit(StreamPid, error);
			      true ->
				  ets:delete(Transfers, JIDSID)
			  end
		  end, Stale),
    ok;

%% Unknown "set" or "get" request
process_iq2(_, #iq{type=Type, sub_el=SubEl} = IQ, _) when Type==get; Type==set ->
    ?DEBUG("unknown IQ: ~p",[IQ]),
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_SERVICE_UNAVAILABLE]};

%% IQ "result" or "error".
process_iq2(_, _, _) ->
    ok.

process_adhoc(_, #adhoc_request{action = "cancel", node = Node}, _) ->
    #adhoc_response{status = canceled, node = Node};

process_adhoc(From, #adhoc_request{node = "browse", action = Action, xdata = XData}, _)
  when XData == false; Action == "prev" ->
    % JID from prev or default to user himself
    FromBare = jlib:jid_to_string(#jid{user = From#jid.user,
				       server = From#jid.server,
				       resource = ""}),
    case XData of
	{xmlelement, _, _, _} ->
	    FieldValues = jlib:parse_xdata_submit(XData),
	    case lists:keysearch("jid", 1, FieldValues) of
		{value, {"jid", [JID2]}} -> JID = JID2;
		_ -> JID = FromBare
	    end;
	_ ->
	    JID = FromBare
    end,

    #adhoc_response{node = "browse",
		    status = executing,
		    defaultaction = "next", actions = ["next"],
		    elements = [{xmlelement, "x",
				 [{"xmlns", ?NS_XDATA},
				  {"type", "form"}],
				 [{xmlelement, "title", [],
				   [{xmlcdata, "Browse/get files of a user"}]},
				  {xmlelement, "instructions", [],
				   [{xmlcdata, "Enter the Jabber-Id of the user whose files you want to browse."}]},
				  {xmlelement, "field",
				   [{"var", "jid"},
				    {"label", "Jabber-Id"},
				    {"type", "jid-single"}],
				   [{xmlelement, "value", [], [{xmlcdata, JID}]}]}
				 ]}]
		    };

process_adhoc(From, #adhoc_request{node = "browse",
				   xdata = XData}, State) ->
    FieldValues = jlib:parse_xdata_submit(XData),
    {value, {"jid", [JID]}} = lists:keysearch("jid", 1, FieldValues),
    case lists:keysearch("files", 1, FieldValues) of
	false ->
	    #adhoc_response{node = "browse",
			    status = executing,
						% TODO: prev
			    defaultaction = "complete", actions = ["prev", "complete"],
			    elements = [{xmlelement, "x",
					 [{"xmlns", ?NS_XDATA},
					  {"type", "form"}],
					 [{xmlelement, "title", [],
					   [{xmlcdata, "Browse/get files of user " ++ JID}]},
					  {xmlelement, "instructions", [],
					   [{xmlcdata, "Select the files you would like to receive."}]},
					  {xmlelement, "field",
					   [{"var", "jid"},
					    {"type", "hidden"}],
					   [{xmlelement, "value", [],
					     [{xmlcdata, JID}]}]},
					  {xmlelement, "field",
					   [{"var", "files"},
					    {"label", "Files"},
					    {"type", "list-multi"}],
					   lists:map(fun({File, Size}) ->
							     {xmlelement, "option",
							      [{"label", io_lib:format("~s (~s)", [File, format_size(Size)])}],
							      [{xmlelement, "value", [],
								[{xmlcdata, File}]}]}
						     end, user_files(State, JID))
					  }]}]
			   };
	{value, {"files", Files}} ->
	    lists:foreach(fun(File) ->
				  offer_file(From, file_path(State, JID, File), State)
			  end, Files),
	    #adhoc_response{node = "browse",
			    status = completed}
    end;

% TODO: delete, statistics

process_adhoc(_, R, _) ->
    ?DEBUG("Unknown adhoc response: ~p",[R]).

offer_file(To, FilePath, #state{my_jid = MyJID, transfers = Transfers}) ->
    SID = randoms:get_string(),
    {ok, #file_info{size = FileSize}} = file:read_file_info(FilePath),
    IQ = #iq{id = randoms:get_string(),
	     type = set,
	     sub_el = [{xmlelement, "si",
			[{"xmlns", ?NS_STREAM_INITIATION},
			 {"id", SID},
			 {"profile", ?PROFILE_FILE_TRANSFER}],
			[{xmlelement, "file",
			  [{"xmlns", ?NS_FILE_TRANSFER},
			   {"name", lists:last(string:tokens(FilePath, "/"))},
			   {"size", io_lib:format("~B", [FileSize])}],
			  []},
			 {xmlelement, "feature",
			  [{"xmlns", ?NS_FEATURE_NEG}],
			  [{xmlelement, "x",
			    [{"xmlns", ?NS_XDATA},
			     {"type", "form"}],
			    [{xmlelement, "field",
			      [{"var", "stream-method"},
			       {"type", "list-single"}],
			      [{xmlelement, "option", [],
				[{xmlelement, "value", [],
				  [{xmlcdata, ?NS_BYTESTREAMS}]
				  }]}]}]}]
			  }]}]},
    ejabberd_router:route(MyJID, To, jlib:iq_to_xml(IQ)),
    ets:insert(Transfers, #transfer{jid_sid = {To, SID},
				    filename = FilePath,
				    filesize = FileSize,
				    state = offer_sent,
				    request_stanza = IQ}),
    ok.

%%
%% Helper functions
%%

make_sockshost(SID, #jid{} = Initiator, Target) ->
    make_sockshost(SID, jlib:jid_to_string(jlib:jid_tolower(Initiator)), Target);
make_sockshost(SID, Initiator, #jid{} = Target) ->
    make_sockshost(SID, Initiator, jlib:jid_to_string(jlib:jid_tolower(Target)));
make_sockshost(SID, Initiator, Target) ->
    sha:sha(SID ++ Initiator ++ Target).


si_find_stream_methods(SI) ->
    {xmlelement, "feature", FeatureNegAttrs, FeatureNegChildren} = xml:get_subtag(SI, "feature"),
    ?NS_FEATURE_NEG = xml:get_attr_s("xmlns", FeatureNegAttrs),
    lists:foldl(fun({xmlelement, "x", XAttrs, XChildren}, R) ->
			case {xml:get_attr_s("xmlns", XAttrs), xml:get_attr_s("type", XAttrs)} of
			    {?NS_XDATA, "form"} ->
				R ++ xdata_fields_find_stream_methods(XChildren);
			    _ ->
				R
			end;
		   (_, R) ->
			R
		end, [], FeatureNegChildren).

xdata_fields_find_stream_methods([{xmlelement, "field", FieldAttrs, FieldChildren} | Els]) ->
    case xml:get_attr_s("var", FieldAttrs) of
	"stream-method" ->
	    lists:foldl(fun({xmlelement, "option", _, _} = OptionEl, R) ->
				[xml:get_subtag_cdata(OptionEl, "value") | R];
			   (_, R) ->
				R
			end, [], FieldChildren);
	_ ->
	    xdata_fields_find_stream_methods(Els)
    end;
xdata_fields_find_stream_methods([_ | Children]) ->
    xdata_fields_find_stream_methods(Children);
xdata_fields_find_stream_methods([]) ->
    [].

bytestreams_query_streamhosts(QueryChildren) ->
    lists:foldr(fun({xmlelement, "streamhost", StreamHostAttrs, _}, R) ->
			JID = xml:get_attr_s("jid", StreamHostAttrs),
			Host = xml:get_attr_s("host", StreamHostAttrs),
			PortS = xml:get_attr_s("port", StreamHostAttrs),
			case {JID, Host, string:to_integer(PortS)} of
			    {[_ | _], [_ | _], {Port, ""}} when is_integer(Port) ->
				[{JID, Host, Port} | R];
			    _ ->
				R
			end;
		   (_, R) ->
			R
		end, [], QueryChildren).

transfer_by_stream_pid(StreamPid, Transfers) ->
    ets:foldl(fun(T = #transfer{stream_pid = Pid}, error) when Pid == StreamPid ->
		      T;
		 (_, R) ->
		      R
	      end, error, Transfers).

transfers_by_jid_request_id(JID, ID, Transfers) ->
    ets:foldl(fun(#transfer{jid_sid = {JID2, _},
			    request_stanza = #iq{id = ID2}} = T, R)
		 when JID =:= JID2, ID =:= ID2 -> [T | R];
		 (_, R) -> R
	      end, [], Transfers).

transfers_by_streamhost_request_id(#jid{} = StreamhostJID, ID, Transfers) ->
    transfers_by_streamhost_request_id(jlib:jid_to_string(StreamhostJID), ID, Transfers);
transfers_by_streamhost_request_id(StreamhostJID, ID, Transfers) ->
    ?DEBUG("transfers_by_streamhost_request_id(~p, ~p, ~p)",[StreamhostJID,ID,Transfers]),
    ets:foldl(fun(#transfer{streamhost = {JID, _, _},
			    request_stanza = #iq{id = ID2}} = T, R)
		 when StreamhostJID =:= JID, ID =:= ID2 -> [T | R];
		 (_, R) -> R
	      end, [], Transfers).

format_size(Size) ->
    format_size(Size, ["B", "KB", "MB", "GB"]).

format_size(Size, [Unit | Units]) when Size < 1024; Units == [] ->
    Format = if
		 is_integer(Size) -> "~B ~s";
		 is_float(Size) -> "~.1f ~s"
	     end,
    io_lib:format(Format, [Size, Unit]);
format_size(Size, [_ | Units]) ->
    format_size(Size / 1024, Units).

%%
%% File location
%%

file_path(State, JID, FilePath) ->
    UserPath = user_path(State, JID),
    FileName = lists:last(string:tokens(FilePath, "/")),
    [_ | _] = FileName,
    true = (FileName =/= "."),
    true = (FileName =/= ".."),
    UserPath ++ "/" ++ FileName.

user_path(#state{basepath = Basepath},
	  #jid{user = User, server = Server}) ->
    UserName = jlib:jid_to_string(#jid{user = User, server = Server, resource = ""}),
    UserName2 = lists:last(string:tokens(UserName, "/")),
    [_ | _] = UserName2,
    true = (UserName2 =/= "."),
    true = (UserName2 =/= ".."),
    Basepath ++ "/" ++ UserName2;
user_path(State, JID) when is_list(JID) ->
    user_path(State, jlib:string_to_jid(JID)).

% -> [{Name, Size}]
user_files(State, JID) ->
    UserPath = user_path(State, JID),
    case file:list_dir(UserPath) of
	{ok, Files} ->
	    lists:map(fun(File) ->
			      case file:read_file_info(UserPath ++ "/" ++ File) of
				  {ok, #file_info{size = Size}} -> FileSize = Size;
				  _ -> FileSize = 0
			      end,
			      {File, FileSize}
		      end, lists:sort(Files));
	{error, _} ->
	    []
    end.

% TODO: quota with transfers