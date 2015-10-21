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
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%% NMEA 0183 application api.
%%%
%%% File: nmea_183.erl <br/>
%%% Created:  9 Sep 2015 by Tony Rogvall
%%% @end
%%%-------------------------------------------------------------------
-module(nmea_0183).

-include("../include/nmea_0183.hrl").

-export([start/0]).
-export([send/1, send_from/2]).


start() ->
    application:start(uart),
    application:start(nmea_0183).

%%--------------------------------------------------------------------
%% @doc
%% sends data to nmea_0183.
%%
%% @end
%%--------------------------------------------------------------------
-spec send(Message::#nmea_message{}) -> ok | {error, Error::atom()}.

send(Message) ->
    nmea_0183_router:send(Message).

%%--------------------------------------------------------------------
%% @doc
%% sends data to nmea_0183.
%%
%% @end
%%--------------------------------------------------------------------
-spec send_from(Pid::pid(), Message::#nmea_message{}) -> 
		  ok | {error, Error::atom()}.

send_from(Pid, Message) ->
    nmea_0183_router:send(Pid, Message).

    
