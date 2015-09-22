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
%%% @author Marina Westman Lonne <malotte@malotte.net>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    Supervisor for nmea_0183 application.
%%%
%%% File: nmea_0183_sup.erl <br/>
%%% Created:  September 2015 by Tony Rogvall
%%% @end
%%%-------------------------------------------------------------------
-module(nmea_0183_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
	 start_link/1,
	 stop/0]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================
-spec start_link(Args::list({Key::atom(), Value::term()})) -> 
			{ok, Pid::pid(), {normal, list()}} | 
			{error, Error::term()}.

start_link() ->
    start_link([]).

start_link(Args) ->
    lager:info("args = ~p.\n", [Args]),
    try supervisor:start_link({local, ?MODULE}, ?MODULE, Args) of
	{ok, Pid} ->
	    {ok, Pid, {normal, Args}};
	Error -> 
	    lager:error("Failed to start process, reason ~p.\n",  [Error]),
	    Error
    catch 
	error:Reason ->
	    lager:error("Try failed, reason ~p.\n", [Reason]),
	    Reason

    end.

%%--------------------------------------------------------------------
%% @doc
%% Stops the server.
%% @end
%%--------------------------------------------------------------------
-spec stop() -> ok.

stop() ->
    exit(normal).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

-spec init(Args::list({Key::atom(), Value::term()})) -> 
		  {ok, {SupFlags::list(), ChildSpecs::list()}} |
		  ignore |
		  {error, Reason::term()}.
init(Args) ->
    Router = {nmea_0183_router, {nmea_0183_router, start_link, [Args]},
	      permanent, 5000, worker, [nmea_0183_router]},
    IfSup = {nmea_0183_if_sup, {nmea_0183_if_sup, start_link, []},
	     permanent, 5000, worker, [nmea_0183_if_sup]},
    {ok,{{one_for_all,3,5}, [Router, IfSup]}}.
