%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2012, Tony Rogvall
%%% @doc
%%%    Save NMEA data to file
%%% @end
%%% Created : 28 Mar 2012 by Tony Rogvall <tony@rogvall.se>

-module(nmea_0183_record).

-compile(export_all).

start(DeviceName) ->
    FileName = filename:join(code:priv_dir(nmea_0183), "latest_log.gps"),
    start(DeviceName, FileName, -1).

start(DeviceName, FileName) ->
    start(DeviceName, FileName, -1).

start(DeviceName, FileName, MaxTime) ->
    case file:open(FileName, [raw,binary,write]) of
	{ok,Fd} ->
	    try start_fd(DeviceName, Fd, MaxTime) of
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

start_fd(DeviceName, Fd, MaxTime) ->
    case uart:open(DeviceName,
		   [{ibaud,4800},{obaud,4800},
		    {active,once},{buffer,1024},{packet,line}]) of
	{ok,Uart} ->
	    if MaxTime > 0 ->
		    erlang:start_timer(MaxTime*1000, self(), stop_record);
	       true ->
		    ok
	    end,
	    Res = loop(Uart, Fd),
	    uart:close(Uart),
	    Res
    end.

loop(Uart, Fd) ->
    receive
	{uart,Uart,Line} ->
	    uart:setopts(Uart, [{active,once}]),
	    file:write(Fd, Line),
	    loop(Uart, Fd);
	{uart_error,Uart,Reason} ->
	    {error,Reason};
	{timeout, _Ref, stop_record} ->
	    ok
    end.
