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
%%% @author Malotte W Lonne <malotte@malotte.net>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%  Nmea 0183 bus interface supervisor
%%%
%%% Created: 2013 by Malotte W Lonne 
%%% @end

-module(nmea_0183_if_sup).

-behaviour(supervisor).

%% external exports
-export([start_link/0, 
	 start_link/1, 
	 stop/1]).

%% supervisor callbacks
-export([init/1]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start_link(Args) ->
    case supervisor:start_link({local, ?MODULE}, ?MODULE, Args) of
	{ok, Pid} ->
	    {ok, Pid, {normal, Args}};
	Error -> 
	    Error
    end.

start_link() ->
    supervisor:start_link({local,?MODULE}, ?MODULE, []).

stop(_StartArgs) ->
    ok.

%%%----------------------------------------------------------------------
%%% Callback functions from supervisor
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%%----------------------------------------------------------------------
init(_Args) ->
    Interfaces = 
	lists:foldr(
	  fun({NmeaMod,If,Opts},Acc) ->
		  Spec={{NmeaMod,If}, 
			{NmeaMod, start_link, [If,Opts]},
			permanent, 5000, worker, [NmeaMod]},
		  [Spec | Acc]
	  end, [], 
	  case application:get_env(nmea_0183, interfaces) of
	      undefined -> [];
	      {ok,IfList} when is_list(IfList) ->
		  IfList
	  end),
    {ok,{{one_for_one,3,5}, Interfaces}}.
