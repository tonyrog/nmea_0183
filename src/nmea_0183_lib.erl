%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    Utilites
%%% @end
%%% Created : 21 Sep 2015 by Tony Rogvall <tony@rogvall.se>

-module(nmea_0183_lib).

-include("../include/nmea_0183.hrl").

-export([parse/2]).
-export([format/1]).
-export([text_expand/2]).

-compile(export_all).

%% Take a NMEA log line from file or uart ...
%% return #name_messagae or {error,Reason}

parse(<<0,Line/binary>>, Intf) ->
    parse(Line, Intf); %% Removing spurious zero
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

format(Message) when is_record(Message, nmea_message) ->
    Body = iolist_to_binary(join([Message#nmea_message.id |
				  Message#nmea_message.fields], $,)),
    Sum = nmea_0183_lib:checksum(Body),
    [$$,Body,$*,tl(integer_to_list(Sum+16#100,16)), "\r\n"].


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

join([H],_Sep) -> [H];
join([H|T],Sep) -> [H,Sep|join(T,Sep)];
join([],_Sep) -> [].

%%
%% Utility to exand environment "variables" in unicode text
%% variables are written as ${var} where var is a encoded atom
%% operating system enviroment is accessed through $(VAR)
%% and application library dir $/app/
%%
text_expand(Text, Env) when is_list(Text) ->
    %% assume unicode character list!
    text_expand_(Text, [], Env);
text_expand(Text, Env) when is_binary(Text) ->
    %% assume utf8 encoded data!
    text_expand_(unicode:characters_to_list(Text), [], Env).

text_expand_([$$,${|Text], Acc, Env) ->
    text_expand_collect_(Text, [], [${,$$], env, Acc, Env);
text_expand_([$$,$(|Text], Acc, Env) ->
    text_expand_collect_(Text, [], [$(,$$], shell, Acc, Env);
text_expand_([$$,$/|Text], Acc, Env) ->
    text_expand_collect_(Text, [], [$/,$$], lib, Acc, Env);
text_expand_([$\\,C|Text], Acc, Env) ->
    text_expand_(Text, [C|Acc], Env);
text_expand_([C|Text], Acc, Env) ->
    text_expand_(Text, [C|Acc], Env);
text_expand_([], Acc, _Env) ->
    lists:reverse(Acc).


text_expand_collect_([$)|Text], Var, _Pre, shell, Acc, Env) ->
    case os:getenv(rev_variable(Var)) of
	false ->
	    text_expand_(Text, Acc, Env);
	Value ->
	    Acc1 = lists:reverse(Value, Acc),
	    text_expand_(Text, Acc1, Env)
    end;
text_expand_collect_([$/|Text], Var, _Pre, lib, Acc, Env) ->
    try erlang:list_to_existing_atom(rev_variable(Var)) of
	App ->
	    case code:lib_dir(App) of
		{error,_} ->
		    text_expand_(Text, Acc, Env);
		Value ->
		    Acc1 = lists:reverse(Value, Acc),
		    text_expand_(Text, Acc1, Env)
	    end
    catch
	error:_ ->
	    text_expand_(Text, Acc, Env)
    end;
text_expand_collect_([$}|Text], Var, _Pre, env, Acc, Env) ->
    try erlang:list_to_existing_atom(rev_variable(Var)) of
	Key ->
	    case lists:keyfind(Key, 1, Env) of
		false ->
		    text_expand_(Text, Acc, Env);
		{_,Val} ->
		    Value = lists:flatten(io_lib:format("~w", [Val])),
		    Acc1 = lists:reverse(Value, Acc),
		    text_expand_(Text, Acc1, Env)
	    end
    catch
	error:_ ->
	    text_expand_(Text, Acc, Env)
    end;
text_expand_collect_([C|Text], Var, Pre, Shell, Acc, Env) ->
    if C >= $a, C =< $z;
       C >= $A, C =< $Z;
       C >= $0, C =< $9;
       C =:= $_; C =:= $@;
       C =:= $\s; C =:= $\t -> %% space and tab allowed in begining and end
	    text_expand_collect_(Text, [C|Var], Pre, Shell, Acc, Env);
       true ->
	    %% char not allowed in variable named
	    text_expand_(Text,  [C | Var ++ Pre ++ Acc], Env)
    end;
text_expand_collect_([], Var, Pre, _Shell, Acc, Env) ->
    text_expand_([],  Var ++ Pre ++ Acc, Env).

rev_variable(Var) ->
    trim_hd(lists:reverse(trim_hd(Var))).

trim_hd([$\s|Cs]) -> trim_hd(Cs);
trim_hd([$\t|Cs]) -> trim_hd(Cs);
trim_hd(Cs) -> Cs.
