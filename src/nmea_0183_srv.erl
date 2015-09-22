%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2012, Tony Rogvall
%%% @doc
%%%    NMEA 0183 GPS application
%%%    Usage: first start the nmea_0183_router with some backend
%%%    Then start this application.
%%% @end
%%% Created : 23 Feb 2012 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(nmea_0183_srv).

-include_lib("lager/include/log.hrl").
-include_lib("kernel/include/file.hrl").
-include("../include/nmea_0183.hrl").

-behaviour(gen_server).

%% API
-export([start/0, start_link/0]).
-export([start/1, start_link/1]).
-export([subscribe/2, unsubscribe/2]).
-export([setopts/2, getopts/2]).
-export([read_log/1, fold_log/6]).
-export([dump_log/0, dump_log/1, dump_log/4]).

-compile(export_all).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).


-record(subscription,
	{
	  pid,
	  mon,
	  timer,
	  ival,
	  pos,
	  loop
	}).

-record(state,
	{
	  long=0.0,        %% last knonw longitude East=(>=0),West=(< 0)
	  lat=0.0,         %% last known latitude  North=(>=0),South(<0)
	  timestamp,       %% UTC seconds
	  time,            %% undefined | {H,M,S}
	  date,            %% undefined | {Y,M,D}
	  speed = 0.0,     %% km/h
	  log,             %% ets table to store data
	  log_pos=0,       %% current insert position
	  log_size=0,      %% size of the log
	  log_loop=0,      %% log loop counter
	  subscriptions=[] %% #subscription{},
	}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------

start_link() ->
    start_link([]).
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

start() ->
    start([]).
start(Opts) ->
    gen_server:start(?MODULE, Opts, []).

setopts(Pid, [{Key,Value}|Opts]) ->
    case gen_server:call(Pid, {setopt,Key,Value}) of
	ok ->
	    setopts(Pid, Opts);
	Error ->
	    {error, {Key,Error}}
    end;
setopts(_Pid, []) ->
    ok.

getopts(Pid, Keys) ->
    getopts(Pid, Keys, []).

getopts(Pid, [Key|Keys], Acc) ->
    case gen_server:call(Pid, {getopt, Key}) of
	{ok,Value} ->
	    getopts(Pid, Keys, [{Key,Value}|Acc]);
	_Error ->
	    getopts(Pid, Keys, Acc)
    end;
getopts(_Pid, [], Acc) ->
    lists:reverse(Acc).

subscribe(Pid, IVal) ->
    gen_server:call(Pid, {subscribe,self(),IVal}).

unsubscribe(Pid, Ref) ->
    gen_server:call(Pid, {unsubscribe,Ref}).

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
init(Opts) ->
    LogSize    = proplists:get_value(log_size, Opts, 4096),
    Log = ets:new(nmea_0183_log, [protected]),
    ok = nmea_0183_router:attach([<<"GPGGA">>,<<"GPRMC">>,<<"GPGSA">>]),
    {ok, #state{ log = Log, log_size = LogSize, log_pos  = 0 }}.

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
handle_call({setopt, log_size, LogSize}, _From, State)
  when is_integer(LogSize), LogSize >= 0, LogSize =< 128*1024 ->
    %% Warning. It's not 100% safe to set log_size, fix proper update!
    {reply, ok, State#state { log_size = LogSize }};

handle_call({getopt,log_size},_From,State) ->
    {reply, {ok,State#state.log_size}, State};
handle_call({getopt,log_pos},_From,State) ->
    {reply, {ok,State#state.log_pos}, State};

handle_call({subscribe,Pid,IVal}, _From, State) when
      is_pid(Pid), is_integer(IVal), IVal >= 100, IVal =< 60000 ->
    %% IVal is the report interval, must calculate aprox min/max!
    Mon = erlang:monitor(process, Pid),
    Timer = erlang:start_timer(IVal, self(), {report,Mon}),
    Pos = State#state.log_pos,   %% position when we start
    Loop = State#state.log_loop, %% check for overwrite
    Sub = #subscription{pid=Pid,mon=Mon,timer=Timer,
			ival=IVal,pos=Pos,loop=Loop},
    Subscriptions = [Sub | State#state.subscriptions],
    {reply, {ok, Mon}, State#state { subscriptions = Subscriptions }};

handle_call({unsubscribe, Ref}, _From, State) ->
    case lists:keytake(Ref, #subscription.mon, State#state.subscriptions) of
	false ->
	    {reply, {error, enoent}, State};
	{value,_Sub,Subscriptions} ->
	    {reply, ok, State#state { subscriptions = Subscriptions }}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error,einval}, State}.

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
handle_cast(_Msg, State) ->
    {noreply, State}.

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

%% GPxxx - GPS receiver
%% LC    - Loran-C
%% OM    - Omega Navigation
%% II    - Integrated instrumentation

handle_info(Message, State) when is_record(Message, nmea_message) ->
    nmea_message(Message, State);

handle_info({timeout,_Timer,{report,Ref}}, State) ->
    case lists:keytake(Ref, #subscription.mon, State#state.subscriptions) of
	false ->
	    {noreply, State};
	{value,S=#subscription{pos=Pos0,loop=Loop0},Subscriptions} ->
	    Log  = State#state.log,
	    Size = State#state.log_size,
	    Pos1 = State#state.log_pos,
	    Loop1 = State#state.log_loop,
	    K0 =
		if Pos0 =< Pos1, Loop0 =:= Loop1 ->
			Pos1 - Pos0;
		   Pos1 =< Pos0, Loop0+1 =:= Loop1 ->
			Size - (Pos0 - Pos1);
		   true ->
			Size
		end,
	    K1 = erlang:min(K0, Size div 2),
	    S#subscription.pid ! {nmea_log, self(), Log, Pos0, K1, Size},
	    Timer1 = erlang:start_timer(S#subscription.ival,
					self(), {report,S#subscription.mon}),
	    Pos = (Pos0 + K1) rem Size,
	    S1 = S#subscription { timer=Timer1,pos=Pos,loop=Loop1},
	    Subscriptions1 = [S1 | Subscriptions],
	    {noreply, State#state { subscriptions = Subscriptions1 }}
    end;

handle_info({'DOWN',Mon,process,_Pid,_Reason}, State) ->
    ?debug("process ~p crashed reason ~p", [_Pid, _Reason]),
    case lists:keytake(Mon, #subscription.mon, State#state.subscriptions) of
	false ->
	    {noreply, State};
	{value,_Sub,Subscriptions} ->
	    {noreply, State#state { subscriptions = Subscriptions }}
    end;

handle_info(_Info, State) ->
    io:format("handle_info: ~p\n", [_Info]),
    {noreply, State}.

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

nmea_message(Message,State) ->
    case {Message#nmea_message.id,Message#nmea_message.fields} of
	{<<"GPGGA">>,
	 [UTC,Lat,LatNS,Long,LongEW,Quality,_SatCount | _Various ]} ->
	    Valid = Quality =/= <<"0">>,
	    set_state(Valid,
		      [{lat,  string_lat_dec(Lat,LatNS)},
		       {long, string_long_dec(Long,LongEW)},
		       {time, string_time(UTC)}], State);
	{<<"GPRMC">>, 
	 [UTC,Status,Lat,LatNS,Long,LongEW,
	  Speed,_TrackAngle,Date | _Various]} ->
	    %% _Various may be variant IGNORE!
	    Valid = Status =:= <<"A">>,
	    set_state(Valid,
		      [{lat,   string_lat_dec(Lat,LatNS)},
		       {long,  string_long_dec(Long,LongEW)},
		       {speed, string_knot_kmh(Speed)},
		       {date,  string_date(Date)},
		       {time,  string_time(UTC)}
		      ], State);
	
	{<<"GPGSA">>, [_Select,_Fix | _Various ]} -> %% ...
	    %% DOP and active satellites
	    {noreply,State};

	{<<"GPGSV">>,[_Num,_I | _Various ]} -> %% ...
	    %% Satellites in view
	    {noreply,State}
    end.


set_state(true, KVs, State) ->
    #state { lat=Lat0, long=Long0, time=Time0, date=Date0 } = State,
    State1 = set_state(KVs, State),
    #state { lat=Lat1, long=Long1, time=Time1, date=Date1 } = State1,
    State2 =
	if Lat0 =/= Lat1; Long0 =/= Long1 ->
		write_position(Lat1, Long1, State1);
	   true ->
		State1
	end,
    State3 =
	if Time0 =/= Time1; Date0 =/= Date1 ->
		write_timestamp(Date1, Time1, State2);
	   true ->
		State2
	end,
    {noreply, State3};
set_state(false, _KVs, State) ->
    {noreply, State}.

set_state([{_Key,undefined}|KVs], State) ->
    set_state(KVs, State);
set_state([{Key,Value}|KVs], State) ->
    case Key of
	lat   -> set_state(KVs, State#state { lat=Value});
	long  -> set_state(KVs, State#state { long=Value});
	speed -> set_state(KVs, State#state { speed=Value});
	date  -> set_state(KVs, State#state { date=Value});
	time  -> set_state(KVs, State#state { time=Value})
    end;
set_state([], State) ->
    State.

-define(UNIX_1970, 62167219200).

write_timestamp(undefined, _Time, State) ->
    State;

write_timestamp(Date, Time, State) ->
    Size = State#state.log_size,
    if Size > 0, Date =/= undefined, Time =/= undefined ->
	    GSec = calendar:datetime_to_gregorian_seconds({Date, Time}),
	    Timestamp = GSec - ?UNIX_1970,
	    ?debug("Timestmp: ~w", [Timestamp]),
	    Pos  = State#state.log_pos,
	    ets:insert(State#state.log, {Pos, {timestamp,Timestamp}}),
	    Pos1 = (Pos + 1) rem Size,
	    Loop =  State#state.log_loop,
	    Loop1 = if Pos1 =:= 0 -> Loop + 1; true -> Loop end,
	    State#state { log_pos = Pos1, log_loop=Loop1,
			  timestamp = Timestamp };
       true ->
	    State
    end.

write_position(Lat, Long, State) ->
    ?debug("Lat:~f, Long:~f~n", [Lat, Long]),
    Pos  = State#state.log_pos,
    Size = State#state.log_size,
    if Size > 0 ->
	    ets:insert(State#state.log, {Pos, {position,Lat,Long}}),
	    Pos1 = (Pos + 1) rem Size,
	    Loop =  State#state.log_loop,
	    Loop1 = if Pos1 =:= 0 -> Loop + 1; true -> Loop end,
	    State#state { log_pos = Pos1, log_loop=Loop1 };
       true ->
	    State
    end.

%% debug flush nmea_log events
dump_log() ->
    receive
	Ent = {nmea_log,_NmeaPid,_Tab,_Pos,_Len,_Size} ->
	    dump_log(Ent),
	    dump_log()
    after 0 ->
	    ok
    end.

dump_log({nmea_log,_NmeaPid,Tab,Pos,Len,Size}) ->
    dump_log(Tab,Pos,Len,Size).

dump_log(Tab,Pos,Len,Size) ->
    fold_log(Tab, Pos, Len, Size, 
		     fun(P,_Acc) ->
			     io:format("~w\n", [P])
		     end, []).
	    
%% retreive data items from nmea log table
read_log({nmea_log,_NmeaPid,Tab,Pos,Len,Size}) ->
    Items=fold_log(Tab, Pos, Len, Size, fun(P,Acc) -> [P|Acc] end, []),
    lists:reverse(Items).
		       
fold_log(_Tab, _Pos, 0, _Size, _Fun, Acc) ->
    Acc;
fold_log(Tab, Pos, Len, Size, Fun, Acc) ->
    case ets:lookup(Tab, Pos) of
	[{_,{position,Lat,Long}}] ->
	    Acc1 = Fun({position,Lat,Long}, Acc),
	    fold_log(Tab, (Pos+1) rem Size, Len-1, Size,
		     Fun, Acc1);
	[{_,{timestamp, Ts}}] ->
	    Acc1 = Fun({timestamp, Ts}, Acc),
	    fold_log(Tab, (Pos+1) rem Size, Len-1, Size, 
		     Fun, Acc1)
    end.

string_knot_kmh(Speed) ->
    try binary_to_float(Speed) of
	Knot -> knot_to_kmh(Knot)
    catch
	error:_ -> undefined
    end.

integer_position({Lat, Long}) ->
    {trunc((Lat+90.0)*100000),trunc((Long+180.0)*100000)}.

string_date(String) when String =/= <<"">> ->
    try binary_to_integer(String) of
	D0 ->
	    Year = (D0 rem 100) + 2000,
	    D1 = D0 div 100,
	    Month = D1 rem 100,
	    D2 = D1 div 100,
	    Day = (D2 rem 100),
	    {Year,Month,Day}
    catch 
	error:_ ->
	    undefined
    end.

string_time(String) when String =/= <<"">> ->
    try binary_to_number(String) of
	T0f ->
	    T0 = trunc(T0f),
	    Sec = T0 rem 100,
	    T1 = T0 div 100,
	    Min = T1 rem 100,
	    T2 = T1 div 100,
	    Hour = T2 rem 100,
	    {Hour,Min,Sec}
    catch
	error:_ ->
	    undefined
    end.

string_lat_dec(Lat,<<"N">>) -> string_deg_to_dec(Lat);
string_lat_dec(Lat,<<"S">>) -> -string_deg_to_dec(Lat);
string_lat_dec(_Lat,_) -> undefined.

string_long_dec(Long,<<"E">>) -> string_deg_to_dec(Long);
string_long_dec(Long,<<"W">>) -> -string_deg_to_dec(Long);
string_long_dec(_Long,_) -> undefined.

%% convert degree to decimal
string_deg_to_dec(String) ->
    try binary_to_float(String) of
	Deg -> deg_to_dec(Deg)
    catch
	error:_ ->
	    undefined
    end.

deg_to_dec(Deg) ->
    D = trunc(Deg) div 100,
    Min  = Deg - (float(D) * 100.0),
    D + (Min / 60.0).

knot_to_kmh(Knot) ->
    Knot*1.852.

binary_to_number(String) ->
    try binary_to_float(String) of
	Float -> Float
    catch
	error:_ ->
	    binary_to_integer(String)
    end.
