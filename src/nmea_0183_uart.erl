%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2015, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @doc
%%%    Read NMEA 0183 sentences/message from uart interface
%%% @end
%%% Created : 16 Sep 2015 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(nmea_0183_uart).

-behaviour(gen_server).

-include("../include/nmea_0183.hrl").

%% API
-export([start/0, start/1, start/2]).
-export([start_link/0, start_link/1, start_link/2]).
-export([stop/1]).

%% Test API
-export([pause/1, resume/1]).
-export([dump/1]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).

-record(s, {
	  receiver={nmea_0183_router, undefined, 0} ::
	    {Module::atom(), %% Module to join and send to
	     Pid::pid(),     %% Pid if not default server
	     If::integer()}, %% Interface id
	  uart,            %% serial line port id
	  device,          %% device name
	  baud_rate,       %% baud rate to uart
	  offset,          %% Usb port offset
	  retry_interval,  %% Timeout for open retry
	  retry_timer,     %% Timer reference for retry
	  pause = false,   %% Pause input
	  buf = <<>>,      %% parse buffer
	  fs               %% can_filter:new()
	 }).

-type nmea_0183_uart_option() ::
	{device,  DeviceName::string()} |
	{baud,    DeviceBaud::integer()} |
	{retry_interval, ReopenTimeout::timeout()}.

-define(SERVER, ?MODULE).

-define(DEFAULT_RETRY_INTERVAL,  2000).
-define(DEFAULT_BAUDRATE,        4800).
-define(DEFAULT_IF,              0).

-define(COMMAND_TIMEOUT, 500).

%%%===================================================================
%%% API
%%%===================================================================
-spec start() -> {ok,pid()} | {error,Reason::term()}.
start() ->
    start(1,[]).

-spec start(BudId::integer()) -> {ok,pid()} | {error,Reason::term()}.
start(BusId) when is_integer(BusId) ->
    start(BusId,[]).

-spec start(BudId::integer(),Opts::[nmea_0183_uart_option()]) ->
		   {ok,pid()} | {error,Reason::term()}.
start(BusId, Opts) when is_integer(BusId) ->
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

-spec start_link(BusId::integer(),Opts::[nmea_0183_uart_option()]) ->
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

-spec pause(Id::integer()| pid()) -> ok | {error, Error::atom()}.
pause(Id) when is_integer(Id); is_pid(Id) ->
    gen_server:call(server(Id), pause).
-spec resume(Id::integer()| pid()) -> ok | {error, Error::atom()}.
resume(Id) when is_integer(Id); is_pid(Id) ->
    gen_server:call(server(Id), resume).

-spec dump(Id::integer()| pid()) -> ok | {error, Error::atom()}.
dump(Id) when is_integer(Id); is_pid(Id) ->
    gen_server:call(server(Id),dump).

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
    Pause = proplists:get_value(pause, Opts, false),
    Device = case proplists:get_value(device, Opts) of
		 undefined ->
		     %% try environment
		     os:getenv("UART_DEVICE_" ++ integer_to_list(Id));
		 D -> D
	     end,
    Baud = case proplists:get_value(baud, Opts) of
	       undefined ->
		   %% maybe UART_SPEED_<x>
		   case os:getenv("UART_SPEED") of
		       false -> ?DEFAULT_BAUDRATE;
		       ""    -> ?DEFAULT_BAUDRATE;
		       Baud0 -> list_to_integer(Baud0)
		   end;
	       Baud1 -> Baud1
	   end,
    if Device =:= false; Device =:= "" ->
	    lager:error("missing device argument"),
	    {stop, einval};
       true ->
	    case join(Router, Pid, {?MODULE,Device,Id}) of
		{ok, If} when is_integer(If) ->
		    lager:debug("joined: intf=~w", [If]),
		    S = #s{ receiver={Router,Pid,If},
			    device = Device,
			    offset = Id,
			    baud_rate = Baud,
			    retry_interval = RetryInterval,
			    pause = Pause,
			    fs=nmea_0183_filter:new()
			  },
		    lager:info("using device ~s@~w\n", 
			  [Device, Baud]),
		    case open(S) of
			{ok, S1} -> {ok, S1};
			Error -> {stop, Error}
		    end;
		{error, Reason} = E ->
		    lager:error("~p(~p), reason ~p", 
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

handle_call({send,Packet}, _From, S=#s {uart = Uart})  
  when Uart =/= undefined ->
    {Reply,S1} = send_message(Packet,S),
    {reply, Reply, S1};
handle_call({send,Packet}, _From, S) ->
    lager:warning("Packet ~p dropped", [Packet]),
    {reply, ok, S};
handle_call(statistics,_From,S) ->
    {reply,{ok,nmea_0183_counter:list()}, S};
handle_call(pause, _From, S=#s {pause = false, uart = Uart}) 
  when Uart =/= undefined ->
    lager:debug("pause.", []),
    lager:debug("closing device ~s", [S#s.device]),
    R = uart:close(S#s.uart),
    lager:debug("closed ~p", [R]),
    {reply, ok, S#s {pause = true}};
handle_call(pause, _From, S) ->
    lager:debug("pause when not active.", []),
    {reply, ok, S#s {pause = true}};
handle_call(resume, _From, S=#s {pause = true}) ->
    lager:debug("resume.", []),
    case open(S#s {pause = false}) of
	{ok, S1} -> {reply, ok, S1};
	Error -> {reply, Error, S}
    end;
handle_call(resume, _From, S=#s {pause = false}) ->
    lager:debug("resume when not paused.", []),
    {reply, ok, S};
handle_call(dump, _From, S) ->
    lager:debug("dump.", []),
    {reply, {ok, S}, S};
handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call(_Request, _From, S) ->
    lager:debug("unknown request ~p\n", [_Request]),
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
handle_cast({send,Packet}, S=#s {uart = Uart})   
  when Uart =/= undefined ->
    {_, S1} = send_message(Packet, S),
    {noreply, S1};
handle_cast({send,Packet}, S) ->
    lager:warning("Packet ~p dropped", [Packet]),
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
    lager:debug("unknown message ~p\n", [_Mesg]),
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
handle_info({uart,U,Line}, S = #s { receiver = {_Mod,_Pid,If}}) 
	    when S#s.uart =:= U ->
    lager:debug("got data ~p",[Line]),
    case nmea_0183_lib:parse(Line,If) of
	{error,Reason} ->
	    uart:setopts(U, [{active, once}]),
	    lager:warning("read error ~w",[Reason]),
	    {noreply, S};
	Message ->
	    uart:setopts(U, [{active, once}]),
	    input(Message, S),
	    {noreply, S}
    end;
handle_info({uart_error,U,Reason}, S) when U =:= S#s.uart ->
    if Reason =:= enxio ->
	    lager:error("uart error ~p device ~s unplugged?", 
			[Reason,S#s.device]),
	    {noreply, reopen(S)};
       true ->
	    lager:error("uart error ~p for device ~s", 
			[Reason,S#s.device]),
	    {noreply, S}
    end;

handle_info({uart_closed,U}, S) when U =:= S#s.uart ->
    lager:error("uart device closed, will try again in ~p msecs.",
		[S#s.retry_interval]),
    S1 = reopen(S),
    {noreply, S1};

handle_info({timeout,TRef,reopen},S) when TRef =:= S#s.retry_timer ->
    case open(S#s { retry_timer = undefined }) of
	{ok, S1} ->
	    {noreply, S1};
	Error ->
	    {stop, Error, S}
    end;

handle_info(_Info, S) ->
    lager:debug("unknown info ~p", [_Info]),
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

open(S=#s {pause = true}) ->
    {ok, S};
open(S0=#s {device = DeviceName, baud_rate = Baud }) ->
    UartOpts = [{mode,binary}, {baud, Baud}, {packet, line},
		{csize, 8}, {stopb,1}, {parity,none}, {active, once}],
    case uart:open(DeviceName, UartOpts) of
	{ok,Uart} ->
	    lager:debug("~s@~w", [DeviceName,Baud]),
	    {ok, S0#s { uart = Uart }};
	{error,E} when E =:= eaccess; E =:= enoent ->
	    lager:debug("~s@~w  error ~w, will try again in ~p msecs.", 
			[DeviceName,Baud,E,S0#s.retry_interval]),
	    {ok, reopen(S0)};
	Error ->
	    lager:error("error ~w", [Error]),
	    Error
    end.

reopen(S=#s {pause = true}) ->
    S;
reopen(S) ->
    if S#s.uart =/= undefined ->
	    lager:debug("closing device ~s", [S#s.device]),
	    R = uart:close(S#s.uart),
	    lager:debug("closed ~p", [R]),
	    R;
       true ->
	    ok
    end,
    Timer = start_timer(S#s.retry_interval, reopen),
    S#s { uart=undefined, buf=(<<>>), retry_timer=Timer }.

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

%%
%%  Format message as $ <id> (, <field>)* '*' <checsum>\r\n
%%
send_message(Message, S) when is_record(Message, nmea_message) ->
    Data = nmea_0183_lib:format(Message),
    S1 = count(output_packets, S),
    lager:debug("send data ~p",[Data]),
    {uart:send(S#s.uart, Data), S1}.


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

server(Pid) when is_pid(Pid)->
    Pid;
server(BusId) when is_integer(BusId) ->
    nmea_0183_router:interface_pid(BusId).
