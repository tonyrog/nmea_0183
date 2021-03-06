%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2016, Rogvall Invest AB, <tony@rogvall.se>
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
%%% @author Marina Westman Lonne <malotte@malotte.net>
%%% @copyright (C) 2016, Tony Rogvall
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
-export([pause/1, resume/1, ifstatus/1]).
-export([dump/1]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).

-record(s, {
	  name::string(),
	  receiver={nmea_0183_router, undefined, 0} ::
	    {Module::atom(), %% Module to join and send to
	     Pid::pid() | undefined,     %% Pid if not default server
	     If::integer()}, %% Interface id
	  uart,            %% serial line port id
	  device,          %% device name
	  baud_rate,       %% baud rate to uart
	  offset,          %% Usb port offset
	  retry_interval,  %% Timeout for open retry
	  retry_timer,     %% Timer reference for retry
	  pause = false ::boolean(),   %% Pause input
	  alarm = false ::boolean(),
	  buf = <<>>,      %% parse buffer
	  fs               %% can_filter:new()
	 }).

-type nmea_0183_uart_option() ::
	{device,  DeviceName::string()} |
	{name,    IfName::string()} |
	{baud,    DeviceBaud::integer()} |
	{retry_interval, ReopenTimeout::timeout()}.

-define(SUBSYS, ?MODULE).
-define(SERVER, ?MODULE).
-define(ALARM_DOWN, 'interface-down').
-define(ALARM_ERROR, 'interface-error').

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

-spec pause(Id::integer() | pid() | string()) -> ok | {error, Error::atom()}.
pause(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id, pause).
-spec resume(Id::integer() | pid() | string()) -> ok | {error, Error::atom()}.
resume(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id, resume).
-spec ifstatus(If::integer() | pid() | string()) ->
		      {ok, Status::atom()} | {error, Reason::term()}.
ifstatus(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id, ifstatus).

-spec dump(Id::integer()| pid() | string()) -> ok | {error, Error::atom()}.
dump(Id) when is_integer(Id); is_pid(Id); is_list(Id) ->
    call(Id,dump).

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
    Device = case proplists:get_value(device, Opts) of
		 undefined ->
		     %% try environment
		     os:getenv("UART_DEVICE_" ++ integer_to_list(Id));
		 D -> D
	     end,
    if Device =:= false; Device =:= "" ->
	    lager:error("missing device argument"),
	    {stop, einval};
       true ->
	    Name = proplists:get_value(name, Opts,
				       atom_to_list(?MODULE) ++ "-" ++
					   integer_to_list(Id)),
	    Router = proplists:get_value(router, Opts, nmea_0183_router),
	    Pid = proplists:get_value(receiver, Opts, undefined),
	    RetryInterval = proplists:get_value(retry_interval,Opts,
					       ?DEFAULT_RETRY_INTERVAL),
	    Pause = proplists:get_value(pause, Opts, false),
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
	    case join(Router, Pid, {?MODULE,Device,Id,Name}) of
		{ok, If} when is_integer(If) ->
		    lager:debug("joined: intf=~w", [If]),
		    S = #s{ name = Name,
			    receiver={Router,Pid,If},
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
			{Error, _S1} -> {stop, Error}
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
    lager:debug("Packet ~p dropped", [Packet]),
    {reply, ok, S};
handle_call(statistics,_From,S) ->
    {reply,{ok,nmea_0183_counter:list()}, S};
handle_call(pause, _From, S=#s {pause = false, uart = Uart}) ->
    lager:debug("pause.", []),
    S1 = if Uart =/= undefined ->
		 lager:debug("closing device ~s", [S#s.device]),
		 R = uart:close(S#s.uart),
		 lager:debug("closed ~p", [R]),
		 S#s {uart = undefined};
	    true ->
		 S
	 end,
    elarm:clear(?ALARM_DOWN, ?SUBSYS),
    elarm:clear(?ALARM_ERROR, ?SUBSYS),
    {reply, ok, S1#s {pause = true, alarm = false}};
handle_call(pause, _From, S=#s {pause = true}) ->
    lager:debug("pause when not active.", []),
    {reply, ok, S};
handle_call(resume, _From, S=#s {pause = true}) ->
    lager:debug("resume.", []),
    case open(S#s {pause = false}) of
	{ok, S1} -> {reply, ok, S1};
	{Error, S1} -> {reply, Error, S1}
    end;
handle_call(resume, _From, S=#s {pause = false}) ->
    lager:debug("resume when not paused.", []),
    {reply, ok, S};
handle_call(ifstatus, _From, S=#s {pause = true}) ->
    lager:debug("ifstatus.", []),
    {reply, {ok, paused}, S};
handle_call(ifstatus, _From, S=#s {alarm = true}) ->
    lager:debug("ifstatus.", []),
    {reply, {ok, faulty}, S};
handle_call(ifstatus, _From, S=#s {uart = undefined}) ->
    lager:debug("ifstatus.", []),
    {reply, {ok, faulty}, S};
handle_call(ifstatus, _From, S) ->
    lager:debug("ifstatus.", []),
    {reply, {ok, active}, S};
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
handle_cast({send,_Packet}, S) ->
    lager:debug("Packet ~p dropped", [_Packet]),
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
handle_info({uart,U,Line}, S=#s{receiver = {_Mod,_Pid,If}, uart = U,
				name = Name, device = DeviceName}) ->
    lager:debug("got data ~p",[Line]),
    case nmea_0183_lib:parse(Line,If) of
	{error,Reason} ->
	    uart:setopts(U, [{active, once}]),
	    raise_alarm(?ALARM_ERROR, Name, DeviceName, Reason, 
			[{data, binary_to_list(Line)}]),
	    {noreply, S#s {alarm = true}};
	Message ->
	    elarm:clear(?ALARM_ERROR, ?SUBSYS),
	    uart:setopts(U, [{active, once}]),
	    input(Message, S),
	    {noreply, S#s {alarm = false}}
    end;
handle_info({uart_error,U,Reason},
	    S=#s{uart = U, name = Name, device = DeviceName}) ->
    if Reason =:= enxio ->
	    raise_alarm(?ALARM_DOWN, Name, DeviceName, Reason, 
			[{warning, "maybe unplugged?"}]);
       true ->
	    raise_alarm(?ALARM_DOWN, Name, DeviceName, Reason, [])
    end,
    {noreply, reopen(S#s {alarm = true})};


handle_info({uart_closed,U}, 
	    S=#s{uart = U, name = Name, device = DeviceName}) ->
    raise_alarm(?ALARM_DOWN, Name, DeviceName, uart_closed, []),
    S1 = reopen(S#s {alarm = true}),
    {noreply, S1};

handle_info({timeout,TRef,reopen},S) when TRef =:= S#s.retry_timer ->
    case open(S#s { retry_timer = undefined }) of
	{ok, S1} ->
	    {noreply, S1};
	{Error, S1} ->
	    {stop, Error, S1}
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
open(S0=#s {name = Name, device = DeviceName, baud_rate = Baud }) ->
    UartOpts = [{mode,binary}, {baud, Baud}, {packet, line},
		{csize, 8}, {stopb,1}, {parity,none}, {active, once}],
    case uart:open1(DeviceName, UartOpts) of
	{ok, Uart} ->
	    lager:debug("~s@~w", [DeviceName,Baud]),
	    elarm:clear(?ALARM_DOWN, ?SUBSYS),
	    elarm:clear(?ALARM_ERROR, ?SUBSYS),
	    {ok, S0#s { uart = Uart, alarm = false }};
	{error,E} when E =:= eaccess; E =:= enoent ->
	    lager:debug("~s@~w  error ~w, will try again in ~p msecs.", 
			[DeviceName,Baud,E,S0#s.retry_interval]),
	    raise_alarm(?ALARM_DOWN, Name, DeviceName, E,
			if E =:= enoent -> [{warning, "Maybe unplugged?"}];
			   true -> []
			end),
	    {ok, reopen(S0#s {alarm = true})};
	{error, E} ->
	    raise_alarm(?ALARM_DOWN, Name, DeviceName, E, []),
	    {E, S0#s {alarm = true}}
    end.

reopen(S=#s {pause = true}) ->
    S;
reopen(S=#s {device = DeviceName}) ->
    if S#s.uart =/= undefined ->
	    lager:debug("closing device ~s", [DeviceName]),
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
    {ok,?DEFAULT_IF};
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

raise_alarm(Alarm, Name, DeviceName, Reason, Extra) ->
    elarm:raise(Alarm, ?SUBSYS,
		[{id, Name}, {device, DeviceName},
		 {timestamp, timestamp_us()},
		 {reason, Reason}] ++ Extra).

call(Pid, Request) when is_pid(Pid) -> 
    gen_server:call(Pid, Request);
call(Id, Request) when is_integer(Id); is_list(Id) ->
    Interface = case Id of
		    Name when is_list(Name) -> Name;
		    I when is_integer(I) -> {?MODULE, I}
		end,
    case nmea_0183_router:interface_pid(Interface)  of
	Pid when is_pid(Pid) -> gen_server:call(Pid, Request);
	Error -> Error
    end.

timestamp_us() ->
    try erlang:system_time(micro_seconds)
    catch
	error:undef ->
	    {MS,S,US} = os:timestamp(),
	    (MS*1000000+S)*1000000+US
    end.
