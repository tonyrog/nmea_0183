%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2012, Tony Rogvall
%%% @doc
%%%    Save NMEA data to file
%%% @end
%%% Created : 28 Mar 2012 by Tony Rogvall <tony@rogvall.se>

-module(nmea_0183_record).

-include("../include/nmea_0183.hrl").

-compile(export_all).

start() ->
    FileName = filename:join(code:priv_dir(nmea_0183), "latest_log.gps"),
    start(FileName, -1).

start(FileName) ->
    start(FileName, -1).

start(FileName, MaxTime) ->
    case file:open(FileName, [raw,binary,write]) of
	{ok,Fd} ->
	    try start_fd(Fd, MaxTime) of
		ok -> ok
	    catch
		error:Reason ->
		    {error,Reason}
	    after
		file:close(Fd)
	    end;
	Error ->
	    Error
    end.

start_fd(Fd, MaxTime) ->
    ok = nmea_0183_router:attach(),
    if MaxTime > 0 ->
	    erlang:start_timer(MaxTime*1000, self(), stop_record);
       true ->
	    ok
    end,
    Res = loop(Fd),
    file:close(Fd),
    Res.

loop(Fd) ->
    receive
	Message when is_record(Message, nmea_message) ->
	    Data = nmea_0183_lib:format(Message),
	    file:write(Fd, Data),
	    loop(Fd);
	{timeout, _Ref, stop_record} ->
	    ok
    end.
