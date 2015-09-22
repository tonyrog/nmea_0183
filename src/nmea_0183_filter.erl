%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    PGN soft filter
%%% @end
%%% Created : 28 Aug 2015 by Tony Rogvall <tony@rogvall.se>

-module(nmea_0183_filter).

-export([new/0, new/3, add/3, del/3, get/1, default/2]).
-export([input/2]).

-include("../include/nmea_0183.hrl").
-define(SET_T(), term()).

-record(nmea_fs,
	{
	  accept :: ?SET_T(),
	  reject :: ?SET_T(),
	  default = accept :: accept | reject
	}).

%% create filter structure
new() ->
    #nmea_fs { accept = sets:new(), reject = sets:new() }.

new(Accept,Reject,Default) 
  when is_list(Accept), is_list(Reject), 
       ((Default =:= accept) orelse (Default =:= reject)) ->
    #nmea_fs { accept = sets:from_list(Accept),
	       reject = sets:from_list(Reject),
	       default = Default }.

%% add filter to filter structure
add(Accept,Reject,Fs) 
  when is_list(Accept), is_list(Reject), is_record(Fs, nmea_fs) ->
    Accept1 = sets:union(Fs#nmea_fs.accept, sets:from_list(Accept)),
    Reject1 = sets:union(Fs#nmea_fs.reject, sets:from_list(Reject)),
    Fs#nmea_fs { accept = Accept1, reject = Reject1 }.

del(Accept,Reject,Fs)
  when is_list(Accept), is_list(Reject), is_record(Fs, nmea_fs) ->
    Accept1 = sets:subtract(Fs#nmea_fs.accept, sets:from_list(Accept)),
    Reject1 = sets:subtract(Fs#nmea_fs.reject, sets:from_list(Reject)),
    Fs#nmea_fs { accept = Accept1, reject = Reject1 }.

default(Default, Fs) when Default =:= accept; Default =:= reject ->
    Fs#nmea_fs { default = Default }.

get(Fs) when is_record(Fs, nmea_fs) ->
    {ok, [{accept,sets:to_list(Fs#nmea_fs.accept)},
	  {reject,sets:to_list(Fs#nmea_fs.reject)},
	  {default, Fs#nmea_fs.default }]}.

%% filter a NMEA 0183 message
%% return true for no filtering (pass through)
%% return false for filtering
%%
input(M, Fs) when is_record(M, nmea_message), is_record(Fs, nmea_fs) ->
    case sets:is_element(M#nmea_message.id, Fs#nmea_fs.reject) of
	true -> false;  %% rejected
	false ->
	    case sets:is_element(M#nmea_message.id, Fs#nmea_fs.accept) of
		true -> true; %% accepted
		false -> Fs#nmea_fs.default =:= accept
	    end
    end.
