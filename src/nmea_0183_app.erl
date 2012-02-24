-module(nmea_0183_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    nmea_0183_sup:start_link().

stop(_State) ->
    ok.
