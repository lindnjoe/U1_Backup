#!/bin/bash

PROG_NAME=takePhoto.sh

count=${1:-"1"}
interval=${2:-"3"}
file=${1:-"/tmp/capture.jpg"}


is_integer()
{
	[ "$1" -eq "$1" ] 2>/dev/null
	return $?
}

camera_type()
{
	i2c_mipi_result=$(i2cdetect -y 4 0x37 0x37 | grep UU)
	if [ x"$i2c_mipi_result" != x"" ] ; then
		echo "MIPI"
		return
	fi
	if [ -e "/dev/video18" ] ; then
		echo "USB"
		return
	fi
	echo "UNKNOWN"
}

usage()
{
	echo "usage: $PROG_NAME [count [interval [filepath]]]"
	echo
	echo "If no filepath is specified, only one photo will be taken. The default"
	echo "photo filepath is /home/lava/printer_data/camera/capture.png."
	echo
	echo "example:"
	echo "  $PROG_NAME"
	echo "  $PROG_NAME /tmp/capture.jpg"
	echo "  $PROG_NAME 5 /tmp/capture.jpg"
	echo "  $PROG_NAME 5 3 /tmp/capture.jpg"
}

if [ x"$1" == x"help" ] ; then
	usage
	exit 0
fi

if [ "$interval" -lt 1 ] ; then
	interval=1
fi

type=$(camera_type)
if [ x"$type" = x"MIPI" ] ; then
	echo -n "MIPI Camera: "
	if [ x"$3" == x"" ] ; then
		filepath="/home/lava/printer_data/camera/capture.png"
	else
		filepath="$3"
	fi
elif [ x"$type" = x"USB" ] ; then
	echo -n "USB Camera: "
	if [ x"$3" == x"" ] ; then
		filepath="/home/lava/printer_data/camera/capture.jpg"
	else
		filepath="$3"
	fi
else
	echo "Unknown type, do nothing."
	exit 1
fi

echo "capture $count photos with $interval seconds interval between each."

if is_integer "$count" ; then
	echo 'Save the capture file to '$(dirname "$filepath")
	id=$RANDOM
	for i in $(seq 1 $count) ; do
		echo "Take photo, count: ${i}"
		json_content="{\"jsonrpc\":\"2.0\",\"method\":\"camera.take_a_photo\",\"params\":{\"reason\":\"debug\",\"timestamp\":true,\"filepath\":\"${filepath}\"},\"id\": ${id}}"
		mosquitto_pub -t camera/request -m "${json_content}"
		id=$((id+1))
		sleep ${interval}
	done
else
	if [ x"$file" != x"" ] ; then
		filepath="$file"
	fi
	echo 'Save the capture file to '$(dirname "$filepath")
	id=$RANDOM
	json_content="{\"jsonrpc\":\"2.0\",\"method\":\"camera.take_a_photo\",\"params\":{\"reason\":\"debug\",\"timestamp\":false,\"filepath\":\"${filepath}\"},\"id\": ${id}}"
	mosquitto_pub -t camera/request -m "${json_content}"
fi

exit 0
