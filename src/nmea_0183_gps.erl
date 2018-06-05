%%
%% Simple loop to listen for GPS values
%%
-module(nmea_0183_gps).

-compile(export_all).

-include_lib("nmea_0183/include/nmea_0183.hrl").

start() ->
    application:ensure_all_started(nmea_0183),
    spawn(fun() -> init() end).

init() ->
    nmea_0183_router:attach([<<"GPGGA">>]),
    loop(false,{0.0,{0.0,0.0},0.0}).

loop(Valid1,{Time1,Pos1,Spd1}) ->
    receive
	#nmea_message{id = <<"GPGGA">>,fields=[Utc,Lat,La,Lon,Lo,Stat|_]} ->
	    Time2 = gps_utc(Utc),
	    Lat2 = latitude(Lat,La),
	    Lon2 = longitude(Lon,Lo),
	    Stat2 = try binary_to_integer(Stat) of
			Val -> Val 
		    catch error:_ ->
			    -1
		    end,
	    if Valid1,Stat2 >= 0,
	       is_float(Time2),is_float(Lat2),is_float(Lon2) ->
		    Pos2 = {Lat2,Lon2},
		    Dist2 = distance(Pos1,Pos2),
		    FlatDist2 = flat_distance(Pos1,Pos2),
		    Dt = Time2 - Time1,
		    Spd2 = if Dt >= 0.001 ->
				   (Dist2 / Dt) * 3.6;
			      true ->
				   0.0
			   end,
		    FlatSpd2 = if Dt >= 0.001 ->
				       (FlatDist2 / Dt) * 3.6;
				  true ->
				       0.0
			       end,
		    io:format("~w: utc=~f gps=~f,~f dist=~fm fdist=~fm, spd=~fkm/h, fspd=~fkm/h\n",
			      [Stat2,Time2,Lat2,Lon2,Dist2,FlatDist2,
			       Spd2,FlatSpd2]),
		    loop(true,{Time2,Pos2,Spd2});
	       Stat2 >= 0,
	       is_float(Time2),is_float(Lat2),is_float(Lon2) ->
		    Pos2 = {Lat2,Lon2},
		    io:format("~w: utc=~f gps=~f,~f\n",
			      [Stat2,Time2,Lat2,Lon2]),
		    loop(true,{Time2,Pos2,0.0});
	       true ->
		    io:format("~w: utc=~p lat=~p lon=~p\n",
			      [Stat2,Time2,Lat2,Lon2]),
		    loop(Valid1,{Time1,Pos1,Spd1})
	    end;
	Other ->
	    io:format("Got: ~p\n", [Other]),
	    loop(Valid1,{Time1,Pos1,Spd1})
    end.

%% return gps_utc in float seconds since 1970
gps_utc(<<H1,H0,M1,M0,S1,S0,Bin/binary>>) ->
    {Date,_Time} = calendar:universal_time(),
    Time = {(H1-$0)*10 + (H0-$0),
	    (M1-$0)*10 + (M0-$0),
	    (S1-$0)*10 + (S0-$0)},
    DateTime = {Date,Time},
    Seconds = calendar:datetime_to_gregorian_seconds(DateTime) - 62167219200,
    case Bin of
	<<$.,_/binary>> ->
	    Seconds + binary_to_float(<<$0,Bin/binary>>);
	<<>> ->
	    float(Seconds)
    end.

longitude(<<>>,_) -> undefined;
longitude(Coord,<<"W">>) -> -coord_to_deg(Coord);
longitude(Coord,<<"E">>) -> coord_to_deg(Coord);
longitude(_,_) -> undefined.

latitude(<<>>,_) -> undefined;
latitude(Coord,<<"S">>) -> -coord_to_deg(Coord);
latitude(Coord,<<"N">>) -> coord_to_deg(Coord);
latitude(_,_) -> undefined.

%% https://www.movable-type.co.uk/scripts/latlong.html
%% convert (d)ddmm.mmmm -> d(dd) + mm.mmmm/60
coord_to_deg(Min = <<_,$.,_/binary>>) ->
    binary_to_float(Min)/60;
coord_to_deg(Min = <<_,_,$.,_/binary>>) ->
    binary_to_float(Min)/60;
coord_to_deg(Coord = <<D1,_,_,$.,_/binary>>) ->
    <<_,Min/binary>> = Coord,
    (D1-$0)+binary_to_float(Min)/60;
coord_to_deg(Coord = <<D1,D2,_,_,$.,_/binary>>) ->
    <<_,_,Min/binary>> = Coord,    
    (D1-$0)*10+(D2-$0)+binary_to_float(Min)/60;
coord_to_deg(Coord = <<D1,D2,D3,_,_,$.,_/binary>>) ->
    <<_,_,_,Min/binary>> = Coord,
    (D1-$0)*100+(D2-$0)*10+(D3-$0)+binary_to_float(Min)/60;
coord_to_deg(_) -> undefined.

deg_to_rad(Deg) ->
    Deg*(math:pi()/180).

-define(EARTH_RADIUS, 6371000.0).  %% radius in meters

%% return distancs in meters
distance({Lat1,Lon1},{Lat2,Lon2}) ->
    Phi1 = deg_to_rad(Lat1),
    Phi2 = deg_to_rad(Lat2),
    DPhi = deg_to_rad(Lat2-Lat1),
    DLam = deg_to_rad(Lon2-Lon1),
    SinDPhi2 = math:sin(DPhi/2),
    SinDLam2 = math:sin(DLam/2),
    A = SinDPhi2*SinDPhi2 +
	math:cos(Phi1)*math:cos(Phi2)*SinDLam2*SinDLam2,
    C = 2 * math:atan2(math:sqrt(A), math:sqrt(1-A)),
    ?EARTH_RADIUS * C.

%% return distancs in meters
flat_distance({Lat1,Lon1},{Lat2,Lon2}) ->
    Phi1 = deg_to_rad(Lat1),
    Phi2 = deg_to_rad(Lat2),    
    Lam1 = deg_to_rad(Lon1),
    Lam2 = deg_to_rad(Lon2),
    X = (Lam2 - Lam1) * math:cos((Phi1+Phi2)/2),
    Y = (Phi2 - Phi1),
    ?EARTH_RADIUS * math:sqrt(X*X + Y*Y).
