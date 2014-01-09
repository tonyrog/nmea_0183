%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2012, Tony Rogvall
%%% @doc
%%%    NMEA 0183
%%% @end
%%% Created : 23 Feb 2012 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(nmea_0183_srv).

-include_lib("kernel/include/file.hrl").

-behaviour(gen_server).

%% API
-export([start/1, start_link/1]).
-export([start/2, start_link/2]).
-export([subscribe/2, unsubscribe/2]).
-compile(export_all).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(DEFAULT_REOPEN_IVAL, 5000).  %% 5s between reopen attempts

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
	  device,          %% device | file name
	  port,            %% port
	  port_type,       %% device | regular
	  open_time,       %% timestamp when device was opened
	  loop = false,    %% loop at eof, when file input
	  fake_utc=false,  %% adjust UTC in file input
	  reopen_timer,    %% reopen timer
	  reopen_ival,     %%  and it's interval
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
	  subscriptions=[] %% #subscription{}
	}).

-ifdef(debug).
-define(dbg(Fmt,As),
	case get(debug) of
	    true -> io:format("~s:~w: "++(Fmt)++"\n",[?FILE,?LINE|(As)]);
	    _ -> ok
	end).
-else.
-define(dbg(Fmt,As), ok).
-endif.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------

start_link(DeviceName) ->
    start_link(DeviceName,[{loop,true},{fake_utc,true}]).
start_link(DeviceName,Opts) ->
    gen_server:start_link(?MODULE, [DeviceName|Opts], []).

start(DeviceName) ->
    start(DeviceName,[{loop,true},{fake_utc,true}]).
start(DeviceName,Opts) ->
    gen_server:start(?MODULE, [DeviceName|Opts], []).

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
    gen_server:call(Pid, {unsubscribe, Ref}).

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
init([DeviceName|Opts]) ->
    Loop    = proplists:get_value(loop, Opts, false),
    FakeUtc = proplists:get_value(fake_utc, Opts, false),
    ReopenIval = proplists:get_value(repopen_ival, Opts, ?DEFAULT_REOPEN_IVAL),
    LogSize    = proplists:get_value(log_size, Opts, 4096),
    Debug      = proplists:get_value(debug,    Opts, false),
    put(debug, Debug),
    Log = ets:new(nmea_0183_log, [protected]),
    case open(DeviceName) of
	{ok,Type,Port} ->
	    {ok, #state{ device=DeviceName,
			 port=Port,
			 port_type=Type,
			 loop=Loop,
			 fake_utc=FakeUtc,
			 reopen_ival = ReopenIval,
			 open_time=os:timestamp(),
			 log = Log,
			 log_size = LogSize,
			 log_pos  = 0
		       }};
	_Error ->
	    Timer = erlang:start_timer(ReopenIval, self(), reopen),
	    {ok, #state{ device=DeviceName,
			 reopen_timer = Timer,
			 reopen_ival = ReopenIval,
			 loop=Loop,
			 fake_utc=FakeUtc,
			 log = Log,
			 log_size = LogSize,
			 log_pos  = 0
		       }}
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
handle_call({setopt,device,DeviceName}, _From, State) ->
    %% close device if open and reopen
    if State#state.reopen_timer =/= undefined ->
	    {reply, ok, State#state { device = DeviceName }};
       true ->
	    case State#state.port_type of
		regular ->
		    file:close(State#state.port);
		device ->
		    uart:close(State#state.port);
		_ ->
		    ok
	    end,
	    Timer = erlang:start_timer(1, self(), reopen),
	    State1 = State#state { port = undefined,
				   port_type = undefined,
				   reopen_timer = Timer,
				   device = DeviceName },
	    {reply, ok, State1}
    end;
handle_call({setopt,reopen_ival,IVal},_From,State)
  when is_integer(IVal), IVal >= 1000, IVal =< 3600000 ->
    {reply, ok, State#state { reopen_ival = IVal }};
handle_call({setopt, loop, Loop},_From,State)
  when is_boolean(Loop) ->
    {reply, ok, State#state { loop = Loop }};
handle_call({setopt, fake_utc, FakeUtc}, _From, State)
  when is_boolean(FakeUtc) ->
    {reply, ok, State#state { fake_utc = FakeUtc }};
handle_call({setopt, log_size, LogSize}, _From, State)
  when is_integer(LogSize), LogSize >= 0, LogSize =< 128*1024 ->
    %% Warning. It's not 100% safe to set log_size, fix proper update!
    {reply, ok, State#state { log_size = LogSize }};
handle_call({setopt, debug, Debug}, _From, State)
  when is_boolean(Debug) ->
    put(debug, Debug),
    {reply, ok, State};

handle_call({getopt,device},_From,State) ->
    {reply, {ok,State#state.device}, State};
handle_call({getopt,reopen_ival},_From,State) ->
    {reply, {ok,State#state.reopen_ival}, State};
handle_call({getopt,loop},_From,State) ->
    {reply, {ok,State#state.loop}, State};
handle_call({getopt,fake_utc},_From,State) ->
    {reply, {ok,State#state.fake_utc}, State};
handle_call({getopt,log_size},_From,State) ->
    {reply, {ok,State#state.log_size}, State};
handle_call({getopt,log_pos},_From,State) ->
    {reply, {ok,State#state.log_pos}, State};
handle_call({getopt,debug},_From,State) ->
    {reply, {ok,get(debug)}, State};

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

handle_info({uart,U,Line}, State) when State#state.port =:= U ->
    uart:setopt(U, active, once),
    nmea_line(Line, {undefined,undefined}, State);
handle_info({uart_error,Port,enxio}, State) when State#state.port =:= Port ->
    %% any more action here?
    io:format("nmea_0183: enxio: Some one pulled the USB device?\n", []),
    {noreply, State};
handle_info({uart_closed,Port}, State) when State#state.port =:= Port ->
    Timer = erlang:start_timer(State#state.reopen_ival, self(), reopen),
    {noreply, State#state { port=undefined, reopen_timer=Timer}};
handle_info({timeout,_Tmr,port_read}, State) ->
    %% read next line from regular file
    case State#state.port_type of
	regular ->
	    case file:read_line(State#state.port) of
		{ok,Line} ->
		    Length = length(Line),
		    Timeout = trunc(1000*(Length/480)),
		    erlang:start_timer(Timeout, self(), port_read),
		    DateTime =
			if State#state.fake_utc ->
				calendar:now_to_universal_time(os:timestamp());
			   true ->
				{undefined,undefined}
			end,
		    nmea_line(Line,DateTime,State);
		eof ->
		    %% note! empty files will be read 10 times per sec!!!
		    %%  maybe add warning if file is empty or close to it
		    if State#state.loop ->
			    file:position(State#state.port, bof),
			    erlang:start_timer(100, self(), port_read),
			    {noreply, State};
		       true ->
			    file:close(State#state.port),
			    {noreply, State#state { port=undefined,
						    port_type=undefined }}
		    end
	    end;
	_ ->
	    {noreply, State}
    end;

handle_info({timeout,Timer,reopen}, State)
  when State#state.reopen_timer =:= Timer ->
    case open(State#state.device) of
	{ok,Type,Port} ->
	    {noreply, State#state { port=Port,port_type=Type,
				    open_time=os:timestamp(),
				    reopen_timer = undefined }};
	{error,Reason} ->
	    io:format("unable to open device ~s : ~p\n",
		      [State#state.device, Reason]),
	    Timer1 = erlang:start_timer(State#state.reopen_ival,self(),reopen),
	    {noreply, State#state { port=undefined, reopen_timer=Timer1}}
    end;

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
    ?dbg("process ~p crashed reason ~p", [_Pid, _Reason]),
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

nmea_line(Line,{Date0,Time0},State) when is_list(Line) ->
    Verify = verify_checksum(Line),
    if Verify =:= valid; Verify =:= no_checksum ->
	    case re:split(Line, ",", [{return,list}]) of
		["$GPGGA",UTC,Lat,LatNS,Long,LongEW,Quality,_SatCount |
		 _Various ] ->
		    Valid = Quality =/= "0",
		    set_state(Valid,
			      [{lat, string_lat_dec(Lat,LatNS)},
			       {long, string_long_dec(Long,LongEW)},
			       {time, string_time(UTC,Time0)}], State);

		["$GPRMC",UTC,Status,Lat,LatNS,Long,LongEW,
		 Speed,_TrackAngle,Date | _Various] ->
		    %% _Various may be variant IGNORE!
		    Valid = Status =:= "A",
		    set_state(Valid,
			      [{lat,string_lat_dec(Lat,LatNS)},
			       {long, string_long_dec(Long,LongEW)},
			       {speed, string_knot_kmh(Speed)},
			       {date, string_date(Date,Date0)},
			       {time, string_time(UTC,Time0)}
			      ], State);
		["$GPGSA",_Select,_Fix | _Various ] -> %% ...
		    %% DOP and active satellites
		    {noreply,State};

		["$GPGSV",_Num,_I | _Various ] -> %% ...
		    %% Satellites in view
		    {noreply,State};
		_ ->
		    ?dbg("Line: ~p\n", [Line]),
		    {noreply,State}
	    end;
       true ->
	    ?dbg("nmea_0183: verify error ~p\nLine:~s\n", [Verify,Line]),
	    {noreply,State}
    end.

open(DeviceName) ->
    case file:read_file_info(DeviceName) of
	{ok,Info} ->
	    case Info#file_info.type of
		device ->
		    case uart:open(DeviceName,
				   [{baud,4800},{active,once},
				    {buffer,1024},{packet,line}]) of
			{ok,Port} ->
			    {ok,device,Port};
			Error ->
			    Error
		    end;
		regular ->
		    %% warn if file size is suspiciously small
		    if Info#file_info.size < 80 ->
			    io:format("WARNING: file ~s only has ~w bytes of data\n", [DeviceName, Info#file_info.size]);
		       true ->
			    ok
		    end,
		    case file:open(DeviceName, [read]) of
			{ok,Fd} ->
			    erlang:start_timer(20, self(), port_read),
			    {ok,regular,Fd};
			Error ->
			    Error
		    end;
		_ ->
		    {error, not_supported}
	    end;
	Error ->
	    Error
    end.


%% checksum nmea string
verify_checksum([$$ | Cs]) ->  checksum(Cs, 0);
verify_checksum(_) -> {error, bad_format}.

checksum([$*,X1,X2|_], Sum) ->
    case list_to_integer([X1,X2],16) of
	Sum ->
	    valid;
	_ ->
	    {error,invalid_checksum}
    end;
checksum([$\r,$\n], _Sum) -> no_checksum;
checksum([C|Cs], Sum) ->  checksum(Cs, C bxor Sum);
checksum([],_) -> {error, bad_format}.


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
    GSec = calendar:datetime_to_gregorian_seconds({Date, Time}),
    Timestamp = GSec - ?UNIX_1970,
    ?dbg("Timestmp: ~w", [Timestamp]),
    Pos  = State#state.log_pos,
    Size = State#state.log_size,
    if Size > 0 ->
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
    io:format("Lat:~f, Long:~f~n", [Lat, Long]),
    Pos  = State#state.log_pos,
    Size = State#state.log_size,
%%    if State#state.timestamp =/= undefined, Size > 0 ->
    if Size > 0 ->
	    ets:insert(State#state.log, {Pos, {position,Lat,Long}}),
	    Pos1 = (Pos + 1) rem Size,
	    Loop =  State#state.log_loop,
	    Loop1 = if Pos1 =:= 0 -> Loop + 1; true -> Loop end,
	    State#state { log_pos = Pos1, log_loop=Loop1 };
       true ->
	    State
    end.

string_knot_kmh(Speed) ->
    case string:to_float(Speed) of
	{Knot,""} -> knot_to_kmh(Knot);
	_ -> undefined
    end.

string_date(String,undefined) ->
    {D0,_} = string:to_integer(String),
    Year = (D0 rem 100) + 2000,
    D1 = D0 div 100,
    Month = D1 rem 100,
    D2 = D1 div 100,
    Day = (D2 rem 100),
    {Year,Month,Day};
string_date(_String,FakeDate) ->
    FakeDate.

string_time(String,undefined) ->
    {T0f,_} = string:to_float(String++"."),
    T0 = trunc(T0f),
    Sec = T0 rem 100,
    T1 = T0 div 100,
    Min = T1 rem 100,
    T2 = T1 div 100,
    Hour = T2 rem 100,
    {Hour,Min,Sec};
string_time(_String,FakeTime) ->
    FakeTime.

string_lat_dec(Lat,"N") -> string_deg_to_dec(Lat);
string_lat_dec(Lat,"S") -> -string_deg_to_dec(Lat);
string_lat_dec(_Lat,_) -> undefined.

string_long_dec(Long,"E") -> string_deg_to_dec(Long);
string_long_dec(Long,"W") -> -string_deg_to_dec(Long);
string_long_dec(_Long,_) -> undefined.

%% convert degree to decimal
string_deg_to_dec(String) ->
    case string:to_float(String) of
	{Deg,""} -> deg_to_dec(Deg);
	_ -> undefined
    end.

deg_to_dec(Deg) ->
    D = trunc(Deg) div 100,
    Min  = Deg - (float(D) * 100.0),
    D + (Min / 60.0).

knot_to_kmh(Knot) ->
    Knot*1.852.
