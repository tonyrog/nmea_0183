%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2012, Tony Rogvall
%%% @doc
%%%    NMEA 0183 
%%% @end
%%% Created : 23 Feb 2012 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(nmea_0183_srv).


-behaviour(gen_server).

%% API
-export([start/1, start_link/1]).

-compile(export_all).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 
-define(REOPEN_IVAL, 5000).  %% 5s between reopen attempts

-record(state, 
	{
	  device, %% devie name
	  port,   %% port
	  timer,  %% reopen timer
	  long,   %% last knonw longitude East=(>=0),West=(< 0)
	  lat,    %% last known latitude  North=(>=0),South(<0)
	  time,   %% {H,M,S}
	  date,   %% {Y,M,D}
	  speed   %% km/h
	}).

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
start_link(Device) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Device], []).

start(Device) ->
    gen_server:start({local, ?SERVER}, ?MODULE, [Device], []).

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
init([Device]) ->
    case open(Device) of
	{ok,Port} ->
	    {ok, #state{ device=Device, port=Port }};
	_Error ->
	    Timer = erlang:start_timer(?REOPEN_IVAL, self(), reopen),
	    {ok, #state{ device=Device, timer = Timer }}
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
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

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
    Verify = verify_checksum(Line),
    if Verify =:= valid; Verify =:= no_checksum ->
	    case re:split(Line, ",", [{return,list}]) of
		["$GPGGA",UTC,Lat,LatNS,Long,LongEW,Quality,_SatCount |
		 _Various ] ->
		    Valid = Quality =/= "0",
		    set_state(Valid,
			      [{lat, string_lat_dec(Lat,LatNS)},
			       {long, string_long_dec(Long,LongEW)},
			       {time, string_time(UTC)}], State);
		["$GPRMC",UTC,Status,Lat,LatNS,Long,LongEW,
		 Speed,_TrackAngle,Date | _Various] ->
		    %% _Various may be variant IGNORE!
		    Valid = Status =:= "A",
		    set_state(Valid,
			      [{lat,string_lat_dec(Lat,LatNS)},
			       {long, string_long_dec(Long,LongEW)},
			       {speed, string_knot_kmh(Speed)},
			       {date, string_date(Date)},
			       {time, string_time(UTC)}
			      ], State);
		["$GPGSA",_Select,_Fix | _Various ] -> %% ...
		    %% DOP and active satellites
		    {noreply,State};

		["$GPGSV",_Num,_I | _Various ] -> %% ...
		    %% Satellites in view
		    {noreply,State};
		_ ->
		    io:format("Line: ~p\n", [Line]),
		    {noreply,State}
	    end;
       true ->
	    io:format("nmea_0183: error ~p\n", [Verify]),
	    {noreply,State}
    end;
handle_info({uart_error,Port,enxio}, State) when State#state.port =:= Port ->
    io:format("nmea_0183: enxio: Some one pulled the USB device?\n", []),
    {noreply, State};
handle_info({uart_closed,Port}, State) when State#state.port =:= Port ->
    Tmr = erlang:start_timer(?REOPEN_IVAL, self(), reopen),
    {noreply, State#state { port=undefined, timer=Tmr}};
handle_info({timeout,Timer,reopen}, State) when State#state.timer =:= Timer ->
    case open(State#state.device) of
	{ok,Port} ->
	    {noreply, State#state { port = Port, timer = undefined }};
	{error,Reason} ->
	    io:format("unable to open device ~s : ~p\n",
		      [State#state.device, Reason]),
	    Timer1 = erlang:start_timer(?REOPEN_IVAL, self(), reopen),
	    {noreply, State#state { port=undefined, timer=Timer1}}
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

open(DeviceName) ->
    uart:open(DeviceName,
	      [{ibaud,4800},{obaud,4800},
	       {active,once},{buffer,1024},{packet,line}]).

%% checksum nmea string
verify_checksum([$$ | Cs]) ->  checksum(Cs, 0);
verify_checksum(_) -> {error, bad_format}.

checksum([$*,X1,X2|_], Sum) ->
    case list_to_integer([X1,X2],16) of
	Sum ->
	    valid;
       true ->
	    {error,invalid_checksum}
    end;
checksum([$\r,$\n], _Sum) -> no_checksum;
checksum([C|Cs], Sum) ->  checksum(Cs, C bxor Sum);
checksum([],_) -> {error, bad_format}.


set_state(true, KVs, State) ->
    #state { lat=Lat0, long=Long0 } = State,
    State1 = set_state(KVs, State),
    #state { lat=Lat1, long=Long1 } = State1,
    if Lat0 =/= Lat1; Long0 =/= Long1 ->
	    io:format("Lat:~w, Long: ~w\n", [Lat1, Long1]);
       true ->
	    ok
    end,
    {noreply, State1};
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


string_knot_kmh(Speed) ->
    case string:to_float(Speed) of
	{Knot,""} -> knot_to_kmh(Knot);
	_ -> undefined
    end.

string_date(String) ->
    {D0,_} = string:to_integer(String),
    Year = (D0 rem 100) + 2000,
    D1 = D0 div 100,
    Month = D1 rem 100,
    D2 = D1 div 100,
    Day = (D2 rem 100),
    {Year,Month,Day}.

string_time(String) ->    
    {T0f,_} = string:to_float(String++"."),
    T0 = trunc(T0f),
    Sec = T0 rem 100,
    T1 = T0 div 100,
    Min = T1 rem 100,
    T2 = T1 div 100,
    Hour = T2 rem 100,
    {Hour,Min,Sec}.
    
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
