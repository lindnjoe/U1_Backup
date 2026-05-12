#!/bin/sh

# The hardware version number is mapped through a voltage value, which is obtained through an ADC channel.
# Hardware connection schematic diagram:
#     1.8V --- R74 --+-- R75 --- GND
#                    |
#     SOC ADC0 CH2 __/
#
# The resolution of the ADC is 10 bits, so the ADC value register range is from 0 to 1023. Here, the hardware
# version number is set from V0 to V7. The relationship between the resistance value and the version number is
# as follows:
#
# R74    R75     Voltage    ADC      Judgment Range    Version
# 100K   0R      0V         0        [0, 55]           V0
# 100K   15K     0.23V      134      [75, 200]         V1
# 100K   39K     0.51V      287      [230, 340]        V2
# 100K   68K     0.73       414      [360, 470]        V3
# 100K   120K    0.98       559      [500, 610]        V4
# 100K   220K    1.24V      704      [650, 760]        V5
# 100K   470K    1.48V      844      [790, 900]        V6
# 100K   NC      1.8V       1023     [980, 1023]       V7


# usage
# hwver.sh
# hwver.sh raw

SARADC0_CH2_FILEPATH="/sys/bus/iio/devices/iio:device0/in_voltage2_raw"
SARADC0_CH2_RAW_VALUE=$(cat "$SARADC0_CH2_FILEPATH")

if [ x"$1" = x"raw" ] ; then
	echo "$SARADC0_CH2_RAW_VALUE"
	exit 0
fi

if [ $SARADC0_CH2_RAW_VALUE -le 55 ]; then
	echo "V0"
elif [ $SARADC0_CH2_RAW_VALUE -ge 75 ] && [ $SARADC0_CH2_RAW_VALUE -le 200 ] ; then
	echo "V1"
elif [ $SARADC0_CH2_RAW_VALUE -ge 230 ] && [ $SARADC0_CH2_RAW_VALUE -le 340 ] ; then
	echo "V2"
elif [ $SARADC0_CH2_RAW_VALUE -ge 360 ] && [ $SARADC0_CH2_RAW_VALUE -le 470 ] ; then
	echo "V3"
elif [ $SARADC0_CH2_RAW_VALUE -ge 500 ] && [ $SARADC0_CH2_RAW_VALUE -le 610 ] ; then
	echo "V4"
elif [ $SARADC0_CH2_RAW_VALUE -ge 650 ] && [ $SARADC0_CH2_RAW_VALUE -le 760 ] ; then
	echo "V5"
elif [ $SARADC0_CH2_RAW_VALUE -ge 790 ] && [ $SARADC0_CH2_RAW_VALUE -le 900 ] ; then
	echo "V6"
elif [ $SARADC0_CH2_RAW_VALUE -ge 980 ] ; then
	echo "V7"
else
	echo "Unknown"
fi

exit 0
