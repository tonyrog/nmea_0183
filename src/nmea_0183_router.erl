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
%%%   CAN router
%%%
%%% Created: 21 Sep 2015 by Tony Rogvall
%%% @end
%%%-------------------------------------------------------------------
-module(nmea_0183_router).

-behaviour(gen_server).

%% API
-export([start/0, start/1, stop/0]).
-export([start_link/0, start_link/1]).
-export([join/1, join/2]).
-export([attach/0, attach/1, attach/2, attach/3]).
-export([detach/0]).
-export([send/1, send_from/2]).
-export([sync_send/1, sync_send_from/2]).
-export([input/1, input/2, input_from/2]).
-export([add_filter/3, del_filter/3, default_filter/2, get_filter/1]).
-export([stop/1, restart/1]).
-export([i/0, i/1]).
-export([statistics/0]).
-export([debug/2, interfaces/0, interface/1, interface_pid/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-import(lists, [foreach/2, map/2, foldl/3]).

-include_lib("lager/include/log.hrl").
-include("../include/nmea_0183.hrl").

-define(SERVER, nmea_0183_router).

-record(nmea_if,
	{
	  pid,      %% can interface pid
	  id,       %% interface id
	  mon,      %% can app monitor
	  param     %% match param normally {Mod,Name,Index} 
	}).

-record(nmea_app,
	{
	  pid,       %% can app pid
	  mon,       %% can app monitor
	  interface, %% interface id
	  filter     %% application filter
	 }).

-record(s,
	{
	  if_count = 1,  %% interface id counter
	  apps = []      %% attached can applications
	}).

-define(CLOCK_TIME, 16#ffffffff).
-define(DEFAULT_WAKEUP_TIMEOUT, 15000).
-define(MSG_WAKEUP,            16#2802).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->  start_link([]).

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

statistics() ->
    IFs = gen_server:call(?SERVER, interfaces),
    foldl(
      fun(If,Acc) ->
	      case gen_server:call(If#nmea_if.pid, statistics) of
		  {ok,Stat} ->
		      [{If#nmea_if.id,Stat} | Acc];
		  Error ->
		      [{If#nmea_if.id,Error}| Acc]
	      end
      end, [], IFs).

i() ->
    IFs = gen_server:call(?SERVER, interfaces),
    io:format("Interfaces\n",[]),
    lists:foreach(
      fun(If) ->
	      case gen_server:call(If#nmea_if.pid, statistics) of
		  {ok,Stat} ->
		      print_stat(If, Stat);
		  Error ->
		      io:format("~2w: ~p\n  error = ~p\n",
				[If#nmea_if.id,If#nmea_if.param,Error])
	      end
      end, lists:keysort(#nmea_if.id, IFs)),
    Apps = gen_server:call(?SERVER, applications),
    io:format("Applications\n",[]),
    lists:foreach(
      fun(App) ->
	      Name = case process_info(App#nmea_app.pid, registered_name) of
			 {registered_name, Nm} -> atom_to_list(Nm);
			 _ -> ""
		     end,
	      io:format("~w: ~s interface=~p\n",
			[App#nmea_app.pid,Name,App#nmea_app.interface])
      end, Apps).
    

interfaces() ->
    gen_server:call(?SERVER, interfaces).

interface(Id) ->
    IFs = interfaces(),
    case lists:keysearch(Id, #nmea_if.id, IFs) of
	false ->
	    {error, enoent};
	{value, IF} ->
	    {ok,IF}
    end.

interface_pid(Id) ->
    {ok,IF} = interface(Id),
    IF#nmea_if.pid.

debug(Id, Bool) ->
    call_if(Id, {debug, Bool}).

stop(Id) ->
    call_if(Id, stop).    

restart(Id) ->
    case gen_server:call(?SERVER, {interface,Id}) of
	{ok,If} ->
	    case If#nmea_if.param of
		{nmea_0183_actisense,_,N} ->
		    ok = gen_server:call(If#nmea_if.pid, stop),
		    nmea_0183_actisense:start(N)
		%% add nmea_0183_file
	    end;
	Error ->
	    Error
    end.

i(Id) ->
    case gen_server:call(?SERVER, {interface,Id}) of
	{ok,If} ->
	    case gen_server:call(If#nmea_if.pid, statistics) of
		{ok,Stat} ->
		    print_stat(If, Stat);
		Error ->
		    Error
	    end;
	Error ->
	    Error
    end.

print_stat(If, Stat) ->
    io:format("~2w: ~p\n", [If#nmea_if.id, If#nmea_if.param]),
    lists:foreach(
      fun({Counter,Value}) ->
	      io:format("  ~p: ~w\n", [Counter, Value])
      end, lists:sort(Stat)).

call_if(Id, Request) ->	
    case gen_server:call(?SERVER, {interface,Id}) of
	{ok,If} ->
	    gen_server:call(If#nmea_if.pid, Request);
	{error,enoent} ->
	    io:format("~2w: no such interface\n", [Id]),
	    {error,enoent};
	Error ->
	    Error
    end.

%% attach - simulated can bus or application
attach() ->
    gen_server:call(?SERVER, {attach, self(), {[], [], accept}}).

attach(Accept) when is_list(Accept) ->
    gen_server:call(?SERVER, {attach, self(), {Accept, [], reject}}).

attach(Accept,Reject) when is_list(Accept), is_list(Reject) ->
    gen_server:call(?SERVER, {attach, self(), {Accept, Reject, accept}}).

attach(Accept,Reject,Default) when is_list(Accept), is_list(Reject),
				   ((Default =:= accept)
				    orelse
				    (Default =:= reject)) ->
    gen_server:call(?SERVER, {attach, self(), {Accept, Reject, Default}}).

%% detach the same
detach() ->
    gen_server:call(?SERVER, {detach, self()}).

%% add an interface to the simulated can_bus (may be a real canbus)
join(Params) ->
    gen_server:call(?SERVER, {join, self(), Params}).

join(Pid, Params) ->
    gen_server:call(Pid, {join, self(), Params}).

add_filter(Intf, Accept, Reject) 
  when is_list(Accept), is_list(Reject) ->
    gen_server:call(?SERVER, {add_filter, Intf, Accept, Reject}).

del_filter(Intf, Accept, Reject)
  when is_list(Accept), is_list(Reject) ->
    gen_server:call(?SERVER, {del_filter, Intf, Accept, Reject}).

default_filter(Intf, Default)
  when Default =:= accept; Default =:= reject ->
    gen_server:call(?SERVER, {default_filter, Intf, Default}).

get_filter(Intf) ->
    gen_server:call(?SERVER, {get_filter, Intf}).

send(Message) when is_record(Message, nmea_message) ->
    gen_server:cast(?SERVER, {send, self(), Message}).

send_from(Pid,Message) when is_pid(Pid), is_record(Message, nmea_message) ->
    gen_server:cast(?SERVER, {send, Pid, Message}).

sync_send(Message) when is_record(Message, nmea_message) ->
    gen_server:call(?SERVER, {send, self(), Message}).

sync_send_from(Pid,Message) when is_pid(Pid), is_record(Message, nmea_message) ->
    gen_server:call(?SERVER, {send, Pid, Message}).

%% Input from  backends
input(Message) when is_record(Message, nmea_message) ->
    gen_server:cast(?SERVER, {input, self(), Message}).

input(Pid, Message) when is_record(Message, nmea_message) ->
    gen_server:cast(Pid, {input, self(), Message}).

input_from(Pid,Message) when is_pid(Pid), is_record(Message, nmea_message) ->
    gen_server:cast(?SERVER, {input, Pid, Message}).

%%--------------------------------------------------------------------
%% Shortcut API
%%--------------------------------------------------------------------
start() -> start([]).

start(Args) ->
    application:load(nmea_0183),
    application:set_env(nmea_0183, arguments, Args),
    application:set_env(nmea_0183, interfaces, []),
    application:start(nmea_0183).

stop() ->
    application:stop(nmea_0183).

%%--------------------------------------------------------------------
%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init(_Args) ->
    lager:start(),  %% ok testing, remain or go?
    process_flag(trap_exit, true),
    can_counter:init(stat_in),   %% number of input packets received
    can_counter:init(stat_out),  %% number of output packets  sent
    can_counter:init(stat_err),  %% number of error packets received
    {ok, #s{  }}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({send,Pid,Message},_From, S)
  when is_pid(Pid),is_record(Message, nmea_message) ->
    S1 = do_send(Pid, Message, S),
    {reply, ok, S1}; 

handle_call({attach,Pid,{Accept,Reject,Default}}, _From, S) when is_pid(Pid) ->
    Apps = S#s.apps,
    case lists:keysearch(Pid, #nmea_app.pid, Apps) of
	false ->
	    ?debug("nmea_0183_router: process ~p attached.",  [Pid]),
	    Mon = erlang:monitor(process, Pid),
	    %% We may extend app interface someday - now = 0
	    Fs = nmea_0183_filter:new(Accept,Reject,Default),
	    App = #nmea_app { pid=Pid, mon=Mon, interface=0, filter=Fs },
	    Apps1 = [App | Apps],
	    {reply, ok, S#s { apps = Apps1 }};
	{value,_} ->
	    {reply, ok, S}
    end;
handle_call({detach,Pid}, _From, S) when is_pid(Pid) ->
    Apps = S#s.apps,
    case lists:keysearch(Pid, #nmea_app.pid, Apps) of
	false ->
	    {reply, ok, S};
	{value,App=#nmea_app {}} ->
	    ?debug("nmea_0183_router: process ~p detached.",  [Pid]),
	    Mon = App#nmea_app.mon,
	    erlang:demonitor(Mon),
	    receive {'DOWN',Mon,_,_,_} -> ok
	    after 0 -> ok
	    end,
	    {reply,ok,S#s { apps = Apps -- [App] }}
    end;
handle_call({join,Pid,Param}, _From, S) ->
    case get_interface_by_param(Param) of
	false ->
	    ?debug("nmea_0183_router: process ~p, param ~p joined.",  [Pid, Param]),
	    {ID,S1} = add_if(Pid,Param,S),
	    {reply, {ok,ID}, S1};
	If ->
	    receive
		{'EXIT', OldPid, _Reason} when If#nmea_if.pid =:= OldPid ->
		    ?debug("join: restart detected\n", []),
		    {ID,S1} = add_if(Pid,Param,S),
		    {reply, {ok,ID}, S1}
	    after 0 ->
		    {reply, {error,ealready}, S}
	    end
    end;
handle_call({interface,I}, _From, S) when is_integer(I) ->
    case get_interface_by_id(I) of
	false ->
	    {reply, {error,enoent}, S};
	If ->
	    {reply, {ok,If}, S}
    end;
handle_call({interface,Param}, _From, S) ->
    case get_interface_by_param(Param) of
	false ->
	    {reply, {error,enoent}, S};
	If ->
	    {reply, {ok,If}, S}
    end;
handle_call(interfaces, _From, S) ->
    {reply, get_interface_list(), S};

handle_call(applications, _From, S) ->
    {reply, S#s.apps, S};
handle_call({add_filter,Intf,Accept,Reject}, From, S) ->
    case get_interface_by_id(Intf) of
	false ->
	    {reply, {error, enoent}, S};
	If ->
	    gen_server:cast(If#nmea_if.pid, {add_filter,From,Accept,Reject}),
	    {noreply, S}
    end;
handle_call({del_filter,Intf,Accept,Reject}, From, S) ->
    case get_interface_by_id(Intf) of
	false ->
	    {reply, {error, enoent}, S};
	If ->
	    gen_server:cast(If#nmea_if.pid, {del_filter,From,Accept,Reject}),
	    {noreply, S}
    end;
handle_call({default_filter,Intf,Default}, From, S) ->
    case get_interface_by_id(Intf) of
	false ->
	    {reply, {error, enoent}, S};
	If ->
	    gen_server:cast(If#nmea_if.pid, {default_filter,From,Default}),
	    {noreply, S}
    end;
handle_call({get_filter,Intf}, From, S) ->
    case get_interface_by_id(Intf) of
	false ->
	    {reply, {error, enoent}, S};
	If ->
	    gen_server:cast(If#nmea_if.pid, {get_filter,From}),
	    {noreply, S}
    end;

handle_call(stop, _From, S) ->
    {stop, normal, ok, S};

handle_call(_Request, _From, S) ->
    {reply, {error, bad_call}, S}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({input,Pid,Message}, S) 
  when is_pid(Pid),is_record(Message, nmea_message) ->
    S1 = count(stat_in, S),
    S2 = broadcast(Pid, Message, S1),
    {noreply, S2};
handle_cast({send,Pid,Message}, S) 
  when is_pid(Pid),is_record(Message, nmea_message) ->
    S1 = do_send(Pid, Message, S),
    {noreply, S1};
handle_cast(_Msg, S) ->
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN',_Ref,process,Pid,_Reason},S) ->
    case lists:keytake(Pid, #nmea_app.pid, S#s.apps) of
	false ->
	    case get_interface_by_pid(Pid) of
		false ->
		    {noreply, S};
		If ->
		    ?debug("nmea_0183_router: interface ~p died, reason ~p\n", 
			   [If, _Reason]),
		    erase_interface(If#nmea_if.id),
		    {noreply,S}
	    end;
	{value,_App,Apps} ->
	    ?debug("nmea_0183_router: application ~p died, reason ~p\n", 
		   [_App, _Reason]),
	    %% FIXME: Restart?
	    {noreply,S#s { apps = Apps }}
    end;
handle_info({'EXIT', Pid, Reason}, S) ->
    case get_interface_by_pid(Pid) of
	false ->
	    %% Someone else died, log and terminate
	    ?debug("nmea_0183_router: linked process ~p died, reason ~p, terminating\n", 
		   [Pid, Reason]),
	    {stop, Reason, S};
	If ->
	    %% One of our interfaces died, log and ignore
	    ?debug("nmea_0183_router: interface ~p died, reason ~p\n", 
		   [If, Reason]),
	    erase_interface(If#nmea_if.id),
	    {noreply,S}
    end;
handle_info(_Info, S) ->
    {noreply, S}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _S) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, S, _Extra) ->
    {ok, S}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

count(Counter, S) ->
    can_counter:update(Counter, 1),
    S.

do_send(Pid, Message, S) ->
    case Message#nmea_message.intf of
	0 ->
	    broadcast(Pid,Message,S);
	undefined ->
	    broadcast(Pid,Message,S);
	I ->
	    case get_interface_by_id(I) of
		false -> 
		    S;
		If ->
		    send_if(If,Message,S),
		    S
	    end
    end.

add_if(Pid,Param,S) ->
    Mon = erlang:monitor(process, Pid),
    ID = S#s.if_count,
    If = #nmea_if { pid=Pid, id=ID, mon=Mon, param=Param },
    set_interface(If),
    S1 = S#s { if_count = ID+1 },
    link(Pid),
    {ID, S1}.

%% ugly but less admin for now
set_interface(If) ->
    put({interface,If#nmea_if.id}, If).

erase_interface(I) ->
    erase({interface,I}).

get_interface_by_id(I) ->
    case get({interface,I}) of
	undefined -> false;
	If -> If
    end.
	     
get_interface_by_param(Param) ->
    lists:keyfind(Param, #nmea_if.param, get_interface_list()).

get_interface_by_pid(Pid) ->
    lists:keyfind(Pid, #nmea_if.pid, get_interface_list()).

get_interface_list() ->
    [If || {{interface,_},If} <- get()].

send_if(If, Message, S1) ->
    S2 = count(stat_out, S1),
    gen_server:cast(If#nmea_if.pid, {send, Message}),
    S2.

%% Broadcast a message to applications/simulated can buses
%% and joined CAN interfaces
%% 
broadcast(Sender,Message,S) ->
    S1 = broadcast_apps(Sender, Message, S#s.apps, S),
    broadcast_ifs(Message, get_interface_list(), S1).

%% send to all applications, except sender application
broadcast_apps(Sender, Message, [A|As], S) when A#nmea_app.pid =/= Sender ->
    case nmea_0183_filter:input(Message, A#nmea_app.filter) of
	true ->
	    A#nmea_app.pid ! Message;
	false ->
	    ok
    end,
    broadcast_apps(Sender, Message, As, S);
broadcast_apps(Sender, Message, [_|As], S) ->
    broadcast_apps(Sender, Message, As, S);
broadcast_apps(_Sender, _Message, [], S) ->
    S.

%% send to all interfaces, except the origin interface
broadcast_ifs(Message, [If|Is], S) 
  when If#nmea_if.id =/= Message#nmea_message.intf ->
    S1 = send_if(If, Message, S),
    broadcast_ifs(Message, Is, S1);
broadcast_ifs(Message, [_|Is], S) ->
    broadcast_ifs(Message, Is, S);
broadcast_ifs(_Message, [], S) ->
    S.
