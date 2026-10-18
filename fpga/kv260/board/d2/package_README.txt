d2-probes-20261017: read-only probes for D2's sensor question (docs/spec/soc.md §8.2, the fan; the coordinator:
can the PL SYSMON be read without disturbing the A53's own fan and temperature readings?). soc-2.
tanager-host = d1's plus psrd on the AMS block (0xFFA5_0000, always on; reads have no side effects).
Any Tanager bitstream loaded (sc3 is fine: the PL must be configured for the PL SYSMON to be reachable).

Background: the A53's AMS driver (xilinx-ams; the K26 enables ams_ps and ams_pl) puts both SYSMONs in the
default sequencer mode at boot and disables every alarm. A SYSMONE4 instance in our bitstream would write its
INIT values into the PL SYSMON at every load. What we don't know: whether a load already resets the PL SYSMON
today (no SYSMONE4 in our bitstreams), and which sensor fancontrol's temp1 is.

1. fancontrol's sensor:
     cat /etc/fancontrol
     for h in /sys/class/hwmon/hwmon*; do echo "$h $(cat $h/name) $(readlink -f $h/device)"; done
     grep -H . /sys/bus/iio/devices/iio:device*/name
     ls /sys/bus/iio/devices/iio:device*/ | grep -i temp ; grep -H . /sys/bus/iio/devices/iio:device*/in_temp*_label 2>/dev/null
     the hwmon node's io-channels, if it is an iio-hwmon: find /sys/firmware/devicetree/base -name io-channels | while read f; do echo $f; xxd $f; done
2. The SYSMONs through the AMS:
     sudo ./tanager-host psrd 0xFFA50040 2     AMS_PS_CSTS, AMS_PL_CSTS (is the PL SYSMON reachable)
     sudo ./tanager-host psrd 0xFFA50800       PS SYSMON temperature (LPD): expect about (T + 280.23) x 128.68
     sudo ./tanager-host psrd 0xFFA50C00       PL SYSMON temperature
     sudo ./tanager-host psrd 0xFFA50900 5     PS SYSMON configuration registers 40h-44h
     sudo ./tanager-host psrd 0xFFA50D00 5     PL SYSMON configuration registers 40h-44h
     sudo ./tanager-host psrd 0xFFA50D18 4     PL SYSMON sequence registers (SEQ_CH2, -, SEQ_CH0, SEQ_CH1)
   with `cat /sys/class/hwmon/hwmonN/temp*_input` at the same moment, for the conversion.
3. Optional, when the stress run allows it: unload and reload the app (xmutil unloadapp / loadapp tanager),
   then step 2 again. If the PL SYSMON's configuration registers change (the driver's alarm disables gone),
   a load already resets the PL SYSMON.
Send the raw outputs; soc-2 decodes them.
