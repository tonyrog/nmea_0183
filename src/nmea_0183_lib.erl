%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    Utilites
%%% @end
%%% Created : 21 Sep 2015 by Tony Rogvall <tony@rogvall.se>

-module(nmea_0183_lib).

-include("../include/nmea_0183.hrl").

-compile(export_all).

%% Take a NMEA log line from file or uart ...
%% return #name_messagae or {error,Reason}

parse(Line, Intf) ->
    case binary:split(Line, <<"*">>) of
	[<<$$,Message/binary>>] ->  %% assume no checksum present
	    [ID|Fs] = binary:split(Message, <<",">>, [global]),
	    #nmea_message { id = ID,
			    intf = Intf,
			    fields = Fs};
	[<<$$,Message/binary>>, Cs] ->
	    case verify_checksum(Message, Cs) of
		ok ->
		    [ID|Fs] = binary:split(Message, <<",">>, [global]),
		    #nmea_message { id = ID,
				    intf = Intf,
				    fields = Fs};
		Error ->
		    Error
	    end;
	_ ->
	    {error, no_message}
    end.

verify_checksum(Fs, <<X1,X2,_/binary>>) ->
    Sum = checksum(Fs),
    try list_to_integer([X1,X2],16) of
	Sum -> 
	    ok;
	_ ->
	    {error,invalid_checksum}
    catch
	error:_ ->
	    {error, bad_checksum}
    end.

checksum(Bin) ->
    checksum(Bin, 0).

checksum(<<C,Cs/binary>>, Sum) ->
    checksum(Cs, C bxor Sum);
checksum(<<>>, Sum) ->
    Sum.
