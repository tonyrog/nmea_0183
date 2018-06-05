# NMEA 0183

Modeled after the nmea_2000_router and the can_router,
let you plugin nmea_0183_uart and nmea_0183_log as backends
that generate NMEA 0183 messages as input.

Then use nmea_0813_router:attach() for applications
to subscribe to nmea_message's.

Checkout nmea_0183_srv.erl how to setup subscription and
handle simple nmea_0183 inputs.

To automatically add backends to the nmea_0183_router an
interface list is used in sys.config example:

    {nmea_0183,
      [{interfaces,
         [{nmea_0183_log,0,[{file,"priv/oland_log.gps"}]},
          {nmea_0183_uart,1,[{device,"/dev/ttyUSB0"},{baud, 4800}]}
         ]}]}

The backends can also be started manually with a start function
in the backend, and the backends can also be used standalone
( set options [{router, undefined}, {receiver, self()}] . )
