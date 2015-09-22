%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    Read NMEA 0183 log files + work as a backend to nmea_0183_router
%%% @end
%%% Created :  7 Sep 2015 by Tony Rogvall <tony@rogvall.se>

-module(nmea_0183_log).

-include_lib("lager/include/log.hrl").
-include("../include/nmea_0183.hrl").

-behaviour(gen_server).

-define(is_digit(X), (((X) >= $0) andalso ((X) =< $9))).

%% NMEA 0183 router API
-export([start/0, start/1, start/2]).
-export([start_link/0, start_link/1, start_link/2]).
-export([stop/1]).

%% Direct log API
-export([open/1, close/1]).
-export([read/1, read/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(s, {
	  receiver={nmea_0183_router, undefined, 0} ::
	    {Module::atom(), %% Module to join and send to
	     Pid::pid(),     %% Pid if not default server
	     If::integer()}, %% Interface id
	  file,              %% file name
	  fd,                %% open file descriptor
	  max_rate,        %% Max read frequency
	  retry_interval,  %% Timeout for open retry
	  retry_timer,     %% Timer reference for retry
	  read_timer,      %% Timer for reading data entries
	  last_ts,         %% last time
	  fs               %% can_filter:new()
	 }).

-type nmea_0183_log_option() ::
	{router,    RouterName::atom()} |
	{receiver,  ReceiverPid::pid()} |
	{file,      FileName::string()} |   %% Log file name
	{max_rate,  MaxRate::integer()} |   %% Hz
	{retry_interval, ReopenTimeout::timeout()}.

-define(SERVER, ?MODULE).

-define(DEFAULT_RETRY_INTERVAL,  0183).
-define(DEFAULT_MAX_RATE,        10).    %% 10 Hz
-define(DEFAULT_IF,              0).

%%%===================================================================
%%% API
%%%===================================================================
-spec start() -> {ok,pid()} | {error,Reason::term()}.
start() ->
    start(1,[]).

-spec start(BudId::integer()) -> {ok,pid()} | {error,Reason::term()}.
start(BusId) ->
    start(BusId,[]).

-spec start(BudId::integer(),Opts::[nmea_0183_log_option()]) ->
		   {ok,pid()} | {error,Reason::term()}.
start(BusId, Opts) ->
    nmea_0183:start(),
    ChildSpec= {{?MODULE,BusId}, {?MODULE, start_link, [BusId,Opts]},
		permanent, 5000, worker, [?MODULE]},
    supervisor:start_child(nmea_0183_if_sup, ChildSpec).

-spec start_link() -> {ok,pid()} | {error,Reason::term()}.
start_link() ->
    start_link(1,[]).

-spec start_link(BudId::integer()) -> {ok,pid()} | {error,Reason::term()}.
start_link(BusId) when is_integer(BusId) ->
    start_link(BusId,[]).

-spec start_link(BusId::integer(),Opts::[nmea_0183_log_option()]) ->
			{ok,pid()} | {error,Reason::term()}.
start_link(BusId, Opts) when is_integer(BusId), is_list(Opts) ->
    gen_server:start_link(?MODULE, [BusId,Opts], []).

-spec stop(BusId::integer()) -> ok | {error,Reason::term()}.

stop(BusId) ->
    case supervisor:terminate_child(nmea_0183_if_sup, {?MODULE, BusId}) of
	ok ->
	    supervisor:delete_child(nmea_0183_sup, {?MODULE, BusId});
	Error ->
	    Error
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Id,Opts]) ->
    Router = proplists:get_value(router, Opts, nmea_0183_router),
    Pid = proplists:get_value(receiver, Opts, undefined),
    RetryInterval = proplists:get_value(retry_interval,Opts,
					?DEFAULT_RETRY_INTERVAL),
    MaxRate0 = proplists:get_value(max_rate,Opts,?DEFAULT_MAX_RATE),
    MaxRate = if is_number(MaxRate0), MaxRate0 > 0 -> MaxRate0;
		 true -> ?DEFAULT_MAX_RATE
	      end,
    Accept = proplists:get_value(accept, Opts, []),
    Reject = proplists:get_value(reject, Opts, []),
    Default = proplists:get_value(default, Opts, accept),

    File = proplists:get_value(file, Opts),
    if File =:= undefined ->
	    ?error("nmea_0183_log: missing file argument"),
	    {stop, einval};
       true ->
	    case join(Router, Pid, {?MODULE,File,Id}) of
		{ok, If} when is_integer(If) ->
		    ?debug("nmea_0183_log:joined: intf=~w", [If]),
		    S = #s{ receiver={Router,Pid,If},
			    file = File,
			    max_rate = MaxRate,
			    retry_interval = RetryInterval,
			    fs=nmea_0183_filter:new(Accept,Reject,Default)
			  },
		    ?info("nmea_0183_log: using file ~s\n", [File]),
		    case open_logfile(S) of
			{ok, S1} -> {ok, S1};
			Error -> {stop, Error}
		    end;
		{error, Reason} = E ->
		    lager:error("Failed to join ~p(~p), reason ~p", 
				[Router, Pid, Reason]),
		    {stop, E}
	    end
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_call({send,_Packet}, _From, S) ->
    {reply, {error, read_only}, S};
handle_call(statistics,_From,S) ->
    {reply,{ok,nmea_0183_counter:list()}, S};
handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(_Request, _From, S) ->
    {reply, {error,bad_call}, S}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({send,_Packet}, S) ->
    {noreply, S};
handle_cast({statistics,From},S) ->
    gen_server:reply(From, {ok,nmea_0183_counter:list()}),
    {noreply, S};
handle_cast({add_filter,From,Accept,Reject}, S) ->
    Fs = nmea_0183_filter:add(Accept,Reject,S#s.fs),
    gen_server:reply(From, ok),
    {noreply, S#s { fs=Fs }};
handle_cast({del_filter,From,Accept,Reject}, S) ->
    Fs = nmea_0183_filter:del(Accept,Reject,S#s.fs),
    gen_server:reply(From, ok),
    {noreply, S#s { fs=Fs }};
handle_cast({default_filter,From,Default}, S) ->
    Fs = nmea_0183_filter:default(Default,S#s.fs),
    gen_server:reply(From, ok),
    {noreply, S#s { fs=Fs }};
handle_cast({get_filter,From}, S) ->
    Reply = nmea_0183_filter:get(S#s.fs),
    gen_server:reply(From, Reply),
    {noreply, S};
handle_cast(_Mesg, S) ->
    ?debug("nmea_0183_log: handle_cast: ~p\n", [_Mesg]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_info({timeout,TRef,reopen},S) when TRef =:= S#s.retry_timer ->
    case open_logfile(S#s { retry_timer = undefined }) of
	{ok, S1} ->
	    {noreply, S1};
	Error ->
	    {stop, Error, S}
    end;

handle_info({timeout,Ref,read},S) when Ref =:= S#s.read_timer ->
    if S#s.fd =/= undefined ->
	    case read(S#s.fd, S#s.receiver) of
		eof ->
		    {ok,0} = file:position(S#s.fd, 0),
		    Timer = start_timer(100, read),
		    {noreply, S#s { read_timer = Timer, last_ts = undefined }};
		{error,Reason} ->
		    lager:warning("read error ~w",[Reason]),
		    Td = trunc((1/S#s.max_rate)*1000),
		    Timer = start_timer(Td, read),
		    {noreply, S#s { read_timer = Timer }};
		Message when is_record(Message,nmea_message) ->
		    input(Message, S),
		    Ts = if Message#nmea_message.ts =:= ?NO_TIMESTAMP -> 0;
			    true -> Message#nmea_message.ts
			 end,
		    LastTs = if S#s.last_ts =:= undefined -> Ts;
				true -> S#s.last_ts
			     end,
		    Td = max(Ts - LastTs, trunc((1/S#s.max_rate)*1000)),
		    Timer = start_timer(Td, read),
		    {noreply, S#s { last_ts = Ts, read_timer = Timer }}
	    end;
       true ->
	    {noreply, S}
    end;

handle_info(_Info, S) ->
    ?debug("nmea_0183_log: got info ~p", [_Info]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

open_logfile(S0=#s {file = File }) ->
    case open(File) of
	{ok,Fd} ->
	    ?debug("nmea_0183_log:open: ~s", [File]),
	    Timer = start_timer(100, read),
	    {ok, S0#s { fd = Fd, read_timer = Timer, last_ts = undefined }};
	{error,E} when E =:= eaccess; E =:= enoent ->
	    ?debug("nmea_0183_log:open: ~s  error ~w, will try again "
		   "in ~p msecs.", [File,E,S0#s.retry_interval]),
	    {ok, reopen_logfile(S0)};
	Error ->
	    lager:error("nmea_0183_log: error ~w", [Error]),
	    Error
    end.

reopen_logfile(S) ->
    if S#s.fd =/= undefined ->
	    ?debug("closing file ~s", [S#s.file]),
	    R = close(S#s.fd),
	    ?debug("closed ~p", [R]),
	    R;
       true ->
	    ok
    end,
    Timer = start_timer(S#s.retry_interval, reopen),
    S#s { fd=undefined, retry_timer=Timer }.

start_timer(undefined, _Tag) ->
    undefined;
start_timer(infinity, _Tag) ->
    undefined;
start_timer(Time, Tag) ->
    erlang:start_timer(Time,self(),Tag).

join(Module, Pid, Arg) when is_atom(Module), is_pid(Pid) ->
    Module:join(Pid, Arg);
join(undefined, Pid, _Arg) when is_pid(Pid) ->
    %% No join
    ?DEFAULT_IF;
join(Module, undefined, Arg) when is_atom(Module) ->
    Module:join(Arg).

input(Packet, S=#s {receiver = Receiver, fs = Fs}) ->
    case nmea_0183_filter:input(Packet, Fs) of
	true ->
	    input_packet(Packet, Receiver),
	    count(input_packets, S);
	false ->
	    S1 = count(input_packets, S),
	    count(filter_packets, S1)
    end.

input_packet(Packet, {undefined, Pid, _If}) when is_pid(Pid) ->
    Pid ! Packet;
input_packet(Packet,{Module, undefined, _If}) when is_atom(Module) ->
    Module:input(Packet);
input_packet(Packet,{Module, Pid, _If}) when is_atom(Module), is_pid(Pid) ->
    Module:input(Pid,Packet).

count(Counter,S) ->
    nmea_0183_counter:update(Counter, 1),
    S.

%% fixme: add timestamp variants?

open(File) ->
    file:open(File, [read,binary]).

close(Fd) ->
    file:close(Fd).

read(Fd) ->
    read(Fd, {undefined,self(),0}).

read(Fd, {_Router,_Pid,Intf}) ->
    case file:read_line(Fd) of
	eof -> eof;
	{ok,Line} ->
	    nmea_0183_lib:parse(Line,Intf)
    end.
