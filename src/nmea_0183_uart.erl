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

-include_lib("lager/include/log.hrl").
-include("../include/nmea_0183.hrl").

%% API
-export([start/0, start/1, start/2]).
-export([start_link/0, start_link/1, start_link/2]).
-export([stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

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
	  buf = <<>>,      %% parse buffer
	  fs               %% can_filter:new()
	 }).

-type nmea_0183_uart_option() ::
	{device,  DeviceName::string()} |
	{baud,    DeviceBaud::integer()} |
	{retry_interval, ReopenTimeout::timeout()}.

-define(SERVER, ?MODULE).


-define(DEFAULT_RETRY_INTERVAL,  0183).
-define(DEFAULT_BAUDRATE,        115200).
-define(DEFAULT_IF,              0).

-define(COMMAND_TIMEOUT, 500).

-define(NGT_STARTUP_SEQ, <<16#11, 16#02, 16#00>>).

-define(STX, 16#02).  %% Start packet
-define(ETX, 16#03).  %% End packet
-define(DLE, 16#10).  %% Start pto encode a STX or ETX send DLE+STX or DLE+ETX

-define(N2K_MSG_RECEIVED, 16#93). %% Receive standard N2K message
-define(N2K_MSG_SEND,     16#94). %% Send N2K message
-define(NGT_MSG_RECEIVED, 16#A0). %% Receive NGT specific message
-define(NGT_MSG_SEND,     16#A1). %% Send NGT message

%%%===================================================================
%%% API
%%%===================================================================
-spec start() -> {ok,pid()} | {error,Reason::term()}.
start() ->
    start(1,[]).

-spec start(BudId::integer()) -> {ok,pid()} | {error,Reason::term()}.
start(BusId) ->
    start(BusId,[]).

-spec start(BudId::integer(),Opts::[nmea_0183_uart_option()]) ->
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
	    ?error("nmea_0183_uart: missing device argument"),
	    {stop, einval};
       true ->
	    case join(Router, Pid, {?MODULE,Device,Id}) of
		{ok, If} when is_integer(If) ->
		    ?debug("nmea_0183_uart:joined: intf=~w", [If]),
		    S = #s{ receiver={Router,Pid,If},
			    device = Device,
			    offset = Id,
			    baud_rate = Baud,
			    retry_interval = RetryInterval,
			    fs=nmea_0183_filter:new()
			  },
		    ?info("nmea_0183_uart: using device ~s@~w\n", 
			  [Device, Baud]),
		    case open(S) of
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

handle_call({send,Packet}, _From, S) ->
    {Reply,S1} = send_message(Packet,S),
    {reply, Reply, S1};
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
handle_cast({send,Packet}, S) ->
    {_, S1} = send_message(Packet, S),
    {noreply, S1};
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
    ?debug("nmea_0183_uart: handle_cast: ~p\n", [_Mesg]),
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
handle_info({uart,U,Line}, S) when S#s.uart =:= U ->
    case nmea_0183_lib:parse(Line) of
	{ok,Message} ->
	    uart:setopt(U, active, once),
	    input(Message, S),
	    {noreply, S};
	{error,Reason} ->
	    uart:setopt(U, active, once),
	    lager:warning("nmea_0183_uart: read error ~w",[Reason]),
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
    ?debug("nmea_0183_uart: got info ~p", [_Info]),
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

open(S0=#s {device = DeviceName, baud_rate = Baud }) ->
    UartOpts = [{mode,binary}, {baud, Baud}, {packet, line},
		{csize, 8}, {stopb,1}, {parity,none}, {active, once}],
    case uart:open(DeviceName, UartOpts) of
	{ok,Uart} ->
	    ?debug("nmea_0183_uart:open: ~s@~w", [DeviceName,Baud]),
	    {ok, S0#s { uart = Uart }};
	{error,E} when E =:= eaccess; E =:= enoent ->
	    ?debug("nmea_0183_uart:open: ~s@~w  error ~w, will try again "
		   "in ~p msecs.", [DeviceName,Baud,E,S0#s.retry_interval]),
	    {ok, reopen(S0)};
	Error ->
	    lager:error("nmea_0183_uart: error ~w", [Error]),
	    Error
    end.

reopen(S) ->
    if S#s.uart =/= undefined ->
	    ?debug("closing device ~s", [S#s.device]),
	    R = uart:close(S#s.uart),
	    ?debug("closed ~p", [R]),
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
    Body = iolist_to_binary(join([Message#nmea_message.id|
				  Message#nmea_message.fields], $,)),
    Sum = nmea_0183_lib:checksum(Body),
    Data = [$$,Body,$*,tl(integer_to_list(Sum+16#100,16)), "\r\n"],
    S1 = count(output_packets, S),
    {uart:send(Data), S1}.


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

join([H],_Sep) -> [H];
join([H|T],Sep) -> [H,Sep|join(T,Sep)];
join([],_Sep) -> [].


