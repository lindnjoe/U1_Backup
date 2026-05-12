#!/bin/bash

# Copyright (c) 2026-2030 Snapmaker - Software Development Team
# All rights reserved.
# This is proprietary and confidential code.
# Unauthorized distribution or copying is strictly prohibited.

PROG_NAME=systemUpgrade.sh

MAIN_MCU_VENDOR_NORMAL=1d50
MAIN_MCU_PRODUCT_NORMAL=606f

MAIN_MCU_VENDOR_DFU_MODE=2e3c
MAIN_MCU_PRODUCT_DFU_MODE=df11

PRINT_HEAD_MCU_VENDOR_NORMAL=1d50
PRINT_HEAD_MCU_PRODUCT_NORMAL=614e

PRINT_HEAD_MCU_VENDOR_DFU_MODE=2e3c
PRINT_HEAD_MCU_PRODUCT_DFU_MODE=df11

MAIN_MCU_FIRMWARE_DEFAULT_PATH=/home/lava/firmware_MCU/at32f403a.bin
PRINT_HEAD_MCU_FIRMWARE_DEFAULT_PATH=/home/lava/firmware_MCU/at32f415.bin
MCU_FIRMWARE_MD5SUM_FILE=/home/lava/firmware_MCU/md5sum.txt
MCU_FIRMWARE_VERSION_FILE=/home/lava/firmware_MCU/VERSION

MCU_DEBUG_VERSION_NUMBER="00000000000000-0000000000"

LOG_PREFIX="[UPG]"
LOG_FILE_DIR="/home/lava/printer_data/ota"
LOG_FILE_SUFFIX="system_upgrade_all.log"

PRINT_HEAD_0_IS_CONNECTED="Yes"
PRINT_HEAD_1_IS_CONNECTED="Yes"
PRINT_HEAD_2_IS_CONNECTED="Yes"
PRINT_HEAD_3_IS_CONNECTED="Yes"

NOTIFICATION_ENABLE="No"

# It must be placed in the /tmp directory to ensure that the file does not exist after startup.
RUNNING_FILE_LOCK="/tmp/.system_upgrade.lock"

UPGRADE_UNPACK_TMP_DIR="/tmp/.tmp_upgrade/unpack"

# Load the log common function
LOG_UTILS_SCRIPT="/home/lava/bin/log_utils.sh"
[ -f "$LOG_UTILS_SCRIPT" ] && source "$LOG_UTILS_SCRIPT"

safe_exit()
{
	rm -f "$RUNNING_FILE_LOCK"
	rm -rf "${UPGRADE_UNPACK_TMP_DIR}"
	sync
	exit $1
}

# Enable notification only when upgrade the entire firmware.

# Notify upgrading percent
# Stage:     unpack   mcu0    head0    head1    head2    head3    soc    reboot
# Percent: 1        9      18       37       56       75       93     99
notify_progress_via_mqtt()
{
	if [ x"$NOTIFICATION_ENABLE" = x"Yes" ] ; then
		local percent=$1
		local message=$2
		json_content="{\"jsonrpc\":\"2.0\",\"method\":\"notify_system_upgrade\",\"params\":[{\"state\":\"upgrading\",\"percent\":${percent},\"message\":\"${message}\"}]}"
		mosquitto_pub -t system/notification -m "${json_content}" 2>/dev/null
	fi
}

# Notify upgrade successful
notify_success_via_mqtt()
{
	if [ x"$NOTIFICATION_ENABLE" = x"Yes" ] ; then
		json_content="{\"jsonrpc\":\"2.0\",\"method\":\"notify_system_upgrade\",\"params\":[{\"state\":\"success\",\"reason\":\"upgrade\"}]}"
		mosquitto_pub -t system/notification -m "${json_content}" 2>/dev/null
	fi
}

# Notify upgrade failed
# unit is "UNPACK" | "MCU0" | "HEAD1" | "HEAD2" | "HEAD3" | "HEAD4" | "SOC"
notify_failed_via_mqtt()
{
	if [ x"$NOTIFICATION_ENABLE" = x"Yes" ] ; then
		local unit=$1
		local message=$2
		json_content="{\"jsonrpc\":\"2.0\",\"method\":\"notify_system_upgrade\",\"params\":[{\"state\":\"failed\",\"reason\":\"upgrade\",\"unit\":\"${unit}\",\"message\":\"${message}\"}]}"
		mosquitto_pub -t system/notification -m "${json_content}" 2>/dev/null
	fi
}

# Notify upgrade warning
# unit is "UNPACK" | "MCU0" | "HEAD1" | "HEAD2" | "HEAD3" | "HEAD4" | "SOC"
notify_warning_via_mqtt()
{
	if [ x"$NOTIFICATION_ENABLE" = x"Yes" ] ; then
		local unit=$1
		local message=$2
		json_content="{\"jsonrpc\":\"2.0\",\"method\":\"notify_system_upgrade\",\"params\":[{\"state\":\"warning\",\"reason\":\"upgrade\",\"unit\":\"${unit}\",\"message\":\"${message}\"}]}"
		mosquitto_pub -t system/notification -m "${json_content}" 2>/dev/null
	fi
}

get_mcu_version()
{
	mcu=$1

	case $1 in
		mcu0)
			main_mcu_usb_info=$(lsusb -d "$MAIN_MCU_VENDOR_NORMAL":"$MAIN_MCU_PRODUCT_NORMAL")
			if [ x"$main_mcu_usb_info" != x"" ] ; then
				iproduct=$(lsusb -d "$MAIN_MCU_VENDOR_NORMAL":"$MAIN_MCU_PRODUCT_NORMAL" -v 2>/dev/null | grep iProduct | awk '{print $NF}')
				version=$(echo $iproduct | awk -F'-' '{print $(NF-1) "-" $(NF)}')
				echo $version
			else
				echo "unknown"
			fi
			;;
		head0|head1|head2|head3)
			head_mcu_bus=$(lsusb -d "$PRINT_HEAD_MCU_VENDOR_NORMAL":"$PRINT_HEAD_MCU_PRODUCT_NORMAL" | head -n1 | awk '{print $2}')
			if [ x"$head_mcu_bus" != x"" ] ; then
				if [ x"$mcu" == x"head0" ] ; then
					port="003"
				elif [ x"$mcu" == x"head1" ] ; then
					port="004"
				elif [ x"$mcu" == x"head2" ] ; then
					port="002"
				elif [ x"$mcu" == x"head3" ] ; then
					port="001"
				fi

				head_mcu_usb_info=$(lsusb -t | grep "Class=Communications, Driver=cdc_acm" | grep "Port $port" | awk -F'[,:]' '{print $2}')
				if [ x"$head_mcu_usb_info" != x"" ] ; then
					head_devnum=$(echo $head_mcu_usb_info | awk '{print $2}')
					iproduct=$(lsusb -s "$head_mcu_bus":"$head_devnum" -v 2>/dev/null | grep iProduct | awk '{print $NF}')
					version=$(echo $iproduct | awk -F'-' '{print $(NF-1) "-" $(NF)}')
					echo $version
				else
					echo "unknown"
				fi
			else
				echo "unknown"
			fi
			;;
		*)
			echo "unknown"
			;;
	esac
}

get_unmatch()
{
	failed_list=""
	version_store=$(cat ${MCU_FIRMWARE_VERSION_FILE})

	main_mcu_version=$(get_mcu_version mcu0)
	if [ x"$main_mcu_version" != x"$version_store" ] ; then
		failed_list="${failed_list} mcu0"
	fi

	head_mcu_list="head0 head1 head2 head3"
	for head in $head_mcu_list ; do
		head_mcu_version=$(get_mcu_version $head)
		if [ x"$head_mcu_version" != x"$version_store" ] ; then
			failed_list="${failed_list} ${head}"
		fi
	done

	echo "${failed_list}"
}

revert()
{
	mcu_list="$1"

	if [ x"$mcu_list" == x"" ] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: No MCU need to revert version."
		safe_exit 0
	fi

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Need to revert: $mcu_list."

	retry_max=3
	mcu_version_old=$(head -n 1 $MCU_FIRMWARE_VERSION_FILE)

	# Only revert MCU firmware, do not check
	for mcu in $mcu_list ; do
		case $mcu in
			mcu0)
				for i in $(seq 1 $retry_max) ; do
					# Debug version, do not upgrade
					main_mcu_version=$(get_mcu_version mcu0)
					if [ x"$main_mcu_version" == x"$MCU_DEBUG_VERSION_NUMBER" ] ; then
						echo "${LOG_PREFIX} ${FUNCNAME[0]}: Main MCU use debug version, do not revert."
						break
					fi
					upgrade_main_mcu $MAIN_MCU_FIRMWARE_DEFAULT_PATH
					sleep 1
					# Retry max 6 times
					for ii in $(seq 1 6) ; do
						main_mcu_version=$(get_mcu_version mcu0)
						if [ x"$main_mcu_version" == x"unknown" ] ; then
							sleep 1
						else
							break
						fi
					done
					if [ x"$mcu_version_old" == x"$main_mcu_version" ] ; then
						echo "${LOG_PREFIX} ${FUNCNAME[0]}: Main MCU version revert succeed."
						break
					else
						echo "${LOG_PREFIX} ${FUNCNAME[0]}: Main MCU version revert failed. retry $i."
					fi
				done
				;;
			head0|head1|head2|head3)
				for i in $(seq 1 $retry_max) ; do
					head_mcu_version=$(get_mcu_version $mcu)
					# This print head MCU offline, do not upgrade
					if [ x"$head_mcu_version" == x"unknown" ] ; then
						echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head $mcu offline, try revert."
						# break
					fi
					# Debug version, do not upgrade
					if [ x"$head_mcu_version" == x"$MCU_DEBUG_VERSION_NUMBER" ] ; then
						echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head $mcu use debug version, do not revert."
						break
					fi

					upgrade_head_mcu $mcu $PRINT_HEAD_MCU_FIRMWARE_DEFAULT_PATH

					if { [ "$mcu" = "head0" ] && [ "$PRINT_HEAD_0_IS_CONNECTED" = "No" ]; } ||
						{ [ "$mcu" = "head1" ] && [ "$PRINT_HEAD_1_IS_CONNECTED" = "No" ]; } ||
						{ [ "$mcu" = "head2" ] && [ "$PRINT_HEAD_2_IS_CONNECTED" = "No" ]; } ||
						{ [ "$mcu" = "head3" ] && [ "$PRINT_HEAD_3_IS_CONNECTED" = "No" ]; } ; then
						echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head $mcu is disconnected, do not revert."
						break
					fi
					sleep 2
					# Retry max 6 times
					for ii in $(seq 1 6) ; do
						head_mcu_version=$(get_mcu_version $mcu)
						if [ x"$head_mcu_version" == x"unknown" ] ; then
							sleep 1
						else
							break
						fi
					done
					if [ x"$mcu_version_old" == x"$head_mcu_version" ] ; then
						echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head $mcu version revert succeed."
						break
					else
						echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head $mcu version revert failed. retry $i."
					fi
				done
				;;
			*)
				;;
		esac
	done
}

additional_operations_before_upgrade_all()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Additional operations before upgrade all."
	sync
	echo 3 > /proc/sys/vm/drop_caches
}

upgrade_all()
{
	firmware="$1"

	if [ x"$firmware" == x"" ] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: You must specify a firmware path."
		safe_exit 1
	fi
	if [ ! -f "$firmware" ]; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: $firmware doesn't exist, please check."
		safe_exit 1
	fi

	start_time=$(date "+%Y-%m-%d %H:%M:%S")
	start_time_s=$(date +%s -d "$start_time")
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Upgrade all start: $start_time"

	additional_operations_before_upgrade_all

	notify_progress_via_mqtt 1 "Unpacking"
	rm -rf "${UPGRADE_UNPACK_TMP_DIR}"
	mkdir -p "${UPGRADE_UNPACK_TMP_DIR}"
	upfileUnpack -i "$firmware" -o "${UPGRADE_UNPACK_TMP_DIR}"
	if [ ! $? -eq 0 ] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: Unpack upgrade file failed. Upgrade abort."
		notify_failed_via_mqtt "UNPACK" "Unpack upgrade file failed"
		safe_exit 2
	fi

	end_time_unpack=$(date "+%Y-%m-%d %H:%M:%S")
	end_time_unpack_s=$(date +%s -d "$end_time_unpack")
	duration_unpack_s=$((end_time_unpack_s-start_time_s))
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Unpack duration: ${duration_unpack_s}s"

	notify_progress_via_mqtt 9 "Main MCU"
	# Shutdown klipper process
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Shutdown klipper process."
	/etc/init.d/S60klipper stop
	sleep 1
	lava_io set MAIN_MCU_POWER=1 HEAD_MCU_POWER=1 > /dev/null
	sleep 3

	# Check whether the MCU is upgraded successfully
	revert_mcu_list=""
	retry_max=3
	mcu_version_new=$(head -n 1 ${UPGRADE_UNPACK_TMP_DIR}/MCU_DESC)
	mcu_version_old=$(head -n 1 $MCU_FIRMWARE_VERSION_FILE)

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Prepare to upgrade MCU0."
	have_failure="Yes"
	for i in $(seq 1 $retry_max) ; do
		upgrade_main_mcu ${UPGRADE_UNPACK_TMP_DIR}/at32f403a.bin
		sleep 1
		# Retry max 6 times
		for ii in $(seq 1 6) ; do
			main_mcu_version=$(get_mcu_version mcu0)
			if [ x"$main_mcu_version" == x"unknown" ] ; then
				sleep 1
			else
				break
			fi
		done
		if [ x"$mcu_version_new" == x"$main_mcu_version" ] ; then
			have_failure="No"
			# Add the successful MCU
			revert_mcu_list="mcu0"
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: The MCU0 upgrade was successful."
			notify_progress_via_mqtt 18 "Extruder 1"
			break
		else
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: Main MCU version ($main_mcu_version) check failed after upgrade. retry $i."
		fi
	done
	if [ x"$have_failure" == x"Yes" ] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: Main MCU upgrade failed, revert to old version. Upgrade abort."
		# Revert myself
		revert_mcu_list="mcu0"
		revert "$revert_mcu_list"
		# Notify failed
		notify_failed_via_mqtt "MCU0" "Main MCU upgrade failed"
		# No more upgrade others
		safe_exit 3
	fi

	head_mcu_list="head0 head1 head2 head3"
	for head in $head_mcu_list ; do
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: Prepare to upgrade $head."
		have_failure="Yes"
		for i in $(seq 1 $retry_max) ; do
			head_mcu_version=$(get_mcu_version $head)
			# This print head MCU offline, do not upgrade and think it is successful.
			if [ x"$head_mcu_version" == x"unknown" ] ; then
				echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head $head offline, do not upgrade."
				have_failure="No"
				# Notify warning
				case $head in
					head0)
						notify_warning_via_mqtt "HEAD1" "Extruder 1 offline"
						notify_progress_via_mqtt 37 "Extruder 2"
						;;
					head1)
						notify_warning_via_mqtt "HEAD2" "Extruder 2 offline"
						notify_progress_via_mqtt 56 "Extruder 3"
						;;
					head2)
						notify_warning_via_mqtt "HEAD3" "Extruder 3 offline"
						notify_progress_via_mqtt 75 "Extruder 4"
						;;
					head3)
						notify_warning_via_mqtt "HEAD4" "Extruder 4 offline"
						notify_progress_via_mqtt 93 "Main chip"
						;;
					*) ;;
				esac
				break
			fi
			upgrade_head_mcu $head ${UPGRADE_UNPACK_TMP_DIR}/at32f415.bin
			sleep 2
			# Retry max 6 times
			for ii in $(seq 1 6) ; do
				head_mcu_version=$(get_mcu_version $head)
				if [ x"$head_mcu_version" == x"unknown" ] ; then
					sleep 1
				else
					break
				fi
			done
			if [ x"$mcu_version_new" == x"$head_mcu_version" ] ; then
				have_failure="No"
				# Add this successful MCU
				revert_mcu_list="$revert_mcu_list $head"
				echo "${LOG_PREFIX} ${FUNCNAME[0]}: The Print head $head upgrade was successful."
				case $head in
					head0) notify_progress_via_mqtt 37 "Extruder 2" ;;
					head1) notify_progress_via_mqtt 56 "Extruder 3" ;;
					head2) notify_progress_via_mqtt 75 "Extruder 4" ;;
					head3) notify_progress_via_mqtt 93 "Main chip" ;;
					*) ;;
				esac
				break
			else
				echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head MCU version ($head_mcu_version) check failed. retry $i."
			fi
		done
		if [ x"$have_failure" == x"Yes" ] ; then
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head MCU upgrade failed, revert to old version. Upgrade abort."
			# Revert myself
			revert_mcu_list="$revert_mcu_list $head"
			revert "$revert_mcu_list"
			# Notify failed
			case $head in
				head0) notify_failed_via_mqtt "HEAD1" "Extruder 1 upgrade failed" ;;
				head1) notify_failed_via_mqtt "HEAD2" "Extruder 2 upgrade failed" ;;
				head2) notify_failed_via_mqtt "HEAD3" "Extruder 3 upgrade failed" ;;
				head3) notify_failed_via_mqtt "HEAD4" "Extruder 4 upgrade failed" ;;
				*) ;;
			esac
			# No more upgrade others
			safe_exit 3
		fi
	done

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Prepare to upgrade SOC."
	upgrade_soc ${UPGRADE_UNPACK_TMP_DIR}/update.img
}

additional_operations_before_active()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Additional operations before activating the soc firmware."
	[ -e "/oem/.printer_data" ] && rm -f /oem/.printer_data
	[ -e "/oem/.debug" ] && rm -f /oem/.debug
	sync
}

upgrade_soc()
{
	firmware="$1"

	if [ x"$firmware" == x"" ] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: You must specify a firmware path."
		safe_exit 1
	fi
	if [ ! -f "$firmware" ]; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: $firmware doesn't exist, please check."
		safe_exit 1
	fi

	cmdline=$(cat /proc/cmdline)
	for para in $cmdline ; do
		slotsufix1=$(echo $para | grep "android_slotsufix")
		slotsufix2=$(echo $para | grep "androidboot.slot_suffix")
		if [ x"$slotsufix1" != x"" -o x"$slotsufix2" != x"" ] ; then
			slot=$(echo $slotsufix1 | cut -d '=' -f2)
			if [ x"$slot" == x"" ] ; then
				slot=$(echo $slotsufix2 | cut -d '=' -f2)
			fi
			if [ x"$slot" == x"_a" ] ; then
				slot="A"
				slot_other="B"
			else
				slot="B"
				slot_other="A"
			fi
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: Current slot is $slot, upgrade $slot_other and reboot to active."
			break
		fi
	done

	updateEngine --image_url="$firmware" --update
	sleep 1
	additional_operations_before_active
	rm -rf "${UPGRADE_UNPACK_TMP_DIR}"
	sync

	notify_progress_via_mqtt 99 "Ready to reboot"
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: upgrade soc finish, prepare to reboot."
	sleep 1
	reboot

	notify_success_via_mqtt

	# It usually doesn't be here
	sleep 20
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: reboot failed ? reset force."
	echo b > /proc/sysrq-trigger
}

# If there is no option, do not check whether it is successful.
upgrade_main_mcu()
{
	firmware="$1"
	option=$1

	if [ x"$option" == x"--check" -o x"$option" == x"--force" ] ; then
		firmware=${MAIN_MCU_FIRMWARE_DEFAULT_PATH}

		md5_calc=$(md5sum "${firmware}" | cut -d ' ' -f1)
		md5_store=$(cat ${MCU_FIRMWARE_MD5SUM_FILE} | grep $(basename "${firmware}") | cut -d ' ' -f1)
		if [ x"$md5_calc" != x"$md5_store" ] ; then
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: Failed to check firmware MD5 value."
			safe_exit 1
		fi
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: MD5 check pass."

		if [ x"$option" == x"--check" ] ; then
			version_old=$(get_mcu_version mcu0)
			version_new=$(cat ${MCU_FIRMWARE_VERSION_FILE})
			if [ x"$version_new" == x"$version_old" ] ; then
				echo "${LOG_PREFIX} ${FUNCNAME[0]}: The old and new version are the same, do not upgrade."
				safe_exit 1
			else
				echo "${LOG_PREFIX} ${FUNCNAME[0]}: Current version is $version_old, new version is $version_new."
			fi
		fi
	else
		if [ ! -f "$firmware" ]; then
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: $firmware doesn't exist, please check."
			safe_exit 1
		fi
	fi


	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Main MCU power off."
	lava_io set MAIN_MCU_POWER=0 MAIN_MCU_BOOT=0 > /dev/null
	sleep 1

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Main MCU enter DFU mode and power on."
	lava_io set MAIN_MCU_POWER=1 > /dev/null
	sleep 3

	# Check DFU mode
	dfu_mode_usb_info=$(lsusb -d "$MAIN_MCU_VENDOR_DFU_MODE":"$MAIN_MCU_PRODUCT_DFU_MODE")
	if [ x"$dfu_mode_usb_info" == x"" ] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: Check DFU mode failed, do not upgrade main MCU and return to normal mode. Upgrade abort."
		lava_io set MAIN_MCU_POWER=0 MAIN_MCU_BOOT=1 > /dev/null
		sleep 1
		lava_io set MAIN_MCU_POWER=1 > /dev/null
		return
	fi

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Flash firmware to MCU by DFU tool."
	dfu-util -d ,$MAIN_MCU_VENDOR_DFU_MODE:$MAIN_MCU_PRODUCT_DFU_MODE -a 0 -s 0x8000000:leave -D "$firmware"
	sleep 1

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Main MCU power off and enter normal mode."
	lava_io set MAIN_MCU_POWER=0 MAIN_MCU_BOOT=1 > /dev/null
	sleep 1

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Main MCU power on."
	lava_io set MAIN_MCU_POWER=1 > /dev/null

	if [ x"$option" == x"--check" -o x"$option" == x"--force" ] ; then
		sleep 5
		version_current=$(get_mcu_version mcu0)
		version_store=$(cat ${MCU_FIRMWARE_VERSION_FILE})
		if [ x"$version_current" != x"$version_store" ] ; then
			echo "${LOG_PREFIX} The new version number $version_current is incorrect, please check."
			safe_exit 2
		fi
	fi
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Done."
}

# If there is no option, do not check whether it is successful.
upgrade_head_mcu()
{
	mcu=$1
	firmware="$2"
	option=$2

	if [ x"$option" == x"--check" -o x"$option" == x"--force" ] ; then
		firmware=${PRINT_HEAD_MCU_FIRMWARE_DEFAULT_PATH}

		md5_calc=$(md5sum "${firmware}" | cut -d ' ' -f1)
		md5_store=$(cat ${MCU_FIRMWARE_MD5SUM_FILE} | grep $(basename "${firmware}") | cut -d ' ' -f1)
		if [ x"$md5_calc" != x"$md5_store" ] ; then
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: Failed to check firmware MD5 value."
			safe_exit 1
		fi
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: MD5 check pass."

		if [ x"$option" == x"--check" ] ; then
			version_old=$(get_mcu_version $mcu)
			version_new=$(cat ${MCU_FIRMWARE_VERSION_FILE})
			if [ x"$version_new" == x"$version_old" ] ; then
				echo "${LOG_PREFIX} ${FUNCNAME[0]}: The old and new version are the same, do not upgrade."
				safe_exit 1
			else
				echo "${LOG_PREFIX} ${FUNCNAME[0]}: Current version is $version_old, new version is $version_new."
			fi
		fi
	else
		if [ ! -f "$firmware" ]; then
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: $firmware doesn't exist, please check."
			safe_exit 1
		fi
	fi

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head MCU power off."
	lava_io set HEAD_MCU_POWER=0 > /dev/null

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head MCU $mcu enter DFU mode."
	if [ x"$mcu" == x"head0" ] ; then
		lava_io set HEAD_MCU2_BOOT=0 > /dev/null
	elif [ x"$mcu" == x"head1" ] ; then
		lava_io set HEAD_MCU3_BOOT=0 > /dev/null
	elif [ x"$mcu" == x"head2" ] ; then
		lava_io set HEAD_MCU1_BOOT=0 > /dev/null
	elif [ x"$mcu" == x"head3" ] ; then
		lava_io set HEAD_MCU0_BOOT=0 > /dev/null
	fi
	# !! must waiting for 10s to avoid MCU being broken
	# Reason for T2:
	#   Power off and quickly power on the 5V power supply of the print head,
	#   will causes the voltage to rise to 24V, and damage the print head.
	# sleep 10
	# for PR1:
	# The new version of the hardware no longer requires waiting for as long as the above one (10s).
	sleep 2


	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head MCU power on."
	lava_io set HEAD_MCU_POWER=1 > /dev/null
	sleep 2

	# Check DFU mode
	dfu_mode_usb_info=$(lsusb -d "$MAIN_MCU_VENDOR_DFU_MODE":"$MAIN_MCU_PRODUCT_DFU_MODE")
	if [ x"$dfu_mode_usb_info" == x"" ] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: Check DFU mode failed, do not upgrade $mcu and return to normal mode. Upgrade abort."
		lava_io set HEAD_MCU_POWER=0 > /dev/null
		if [ x"$mcu" == x"head0" ] ; then
			lava_io set HEAD_MCU2_BOOT=1 > /dev/null
			PRINT_HEAD_0_IS_CONNECTED="No"
		elif [ x"$mcu" == x"head1" ] ; then
			lava_io set HEAD_MCU3_BOOT=1 > /dev/null
			PRINT_HEAD_1_IS_CONNECTED="No"
		elif [ x"$mcu" == x"head2" ] ; then
			lava_io set HEAD_MCU1_BOOT=1 > /dev/null
			PRINT_HEAD_2_IS_CONNECTED="No"
		elif [ x"$mcu" == x"head3" ] ; then
			lava_io set HEAD_MCU0_BOOT=1 > /dev/null
			PRINT_HEAD_3_IS_CONNECTED="No"
		fi
		sleep 1
		lava_io set HEAD_MCU_POWER=1 > /dev/null
		return
	fi

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Flash firmware to MCU $mcu by DFU tool."
	dfu-util -d ,$PRINT_HEAD_MCU_VENDOR_DFU_MODE:$PRINT_HEAD_MCU_PRODUCT_DFU_MODE -a 0 -s 0x8000000:leave -D "$firmware"
	sleep 1

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head MCU power off."
	lava_io set HEAD_MCU_POWER=0 > /dev/null

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head MCU "$mcu" enter normal mode."
	if [ x"$mcu" == x"head0" ] ; then
		lava_io set HEAD_MCU2_BOOT=1 > /dev/null
	elif [ x"$mcu" == x"head1" ] ; then
		lava_io set HEAD_MCU3_BOOT=1 > /dev/null
	elif [ x"$mcu" == x"head2" ] ; then
		lava_io set HEAD_MCU1_BOOT=1 > /dev/null
	elif [ x"$mcu" == x"head3" ] ; then
		lava_io set HEAD_MCU0_BOOT=1 > /dev/null
	fi
	sleep 1

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Print head MCU power on"
	lava_io set HEAD_MCU_POWER=1 > /dev/null

	if [ x"$option" == x"--check" -o x"$option" == x"--force" ] ; then
		sleep 5
		version_current=$(get_mcu_version $mcu)
		version_store=$(cat ${MCU_FIRMWARE_VERSION_FILE})
		if [ x"$version_current" != x"$version_store" ] ; then
			echo "The new version number $version_current is incorrect, please check."
			safe_exit 2
		fi
	fi
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: $mcu Done."
}

show_status()
{
	echo "Name                State    Build time      Version"
	echo "Main processor      N/A      "$(cat /etc/FULLVERSION | cut -d_ -f2)"  "$(cat /etc/FULLVERSION | cut -d_ -f1)

	main_mcu_version=$(get_mcu_version mcu0)
	if [ x"$main_mcu_version" != x"unknown" ] ; then
		build_time=$(echo $main_mcu_version | awk -F'-' '{print $1}')
		git_hash=$(echo $main_mcu_version | awk -F'-' '{print $2}')
		echo "Main MCU            online   ${build_time}  $git_hash"
	else
		echo "Main MCU            offline  N/A             N/A"
	fi

	head_mcu_list="head0 head1 head2 head3"
	for head in $head_mcu_list ; do
		head_mcu_version=$(get_mcu_version $head)
		if [ x"$head_mcu_version" != x"unknown" ] ; then
			build_time=$(echo $head_mcu_version | awk -F'-' '{print $1}')
			git_hash=$(echo $head_mcu_version | awk -F'-' '{print $2}')
			echo "Print $head MCU     online   ${build_time}  $git_hash"
		else
			echo "Print $head MCU     offline  N/A             N/A"
		fi
	done
}

check()
{
	result=$(get_unmatch)
	if [ x"$result" != x"" ] ; then
		echo "MCU version check failed, list: ${result}"
		safe_exit 3
	else
		echo "All passed"
		safe_exit 0
	fi
}

check_restore()
{
	result=$(get_unmatch)
	if [ x"$result" != x"" ] ; then
		revert "$result"
		sleep 1
		lava_io set MAIN_MCU_POWER=0 HEAD_MCU_POWER=0
		sleep 1
		lava_io set MAIN_MCU_POWER=1 HEAD_MCU_POWER=1
	fi

	safe_exit 0
}

#        HUB Port   Boot0 ctrl
# head0  003        HEAD_MCU2_BOOT
# head1  004        HEAD_MCU3_BOOT
# head2  002        HEAD_MCU1_BOOT
# head3  001        HEAD_MCU0_BOOT
show_topo()
{
	echo "USB Connection topology:"
	echo "                        /(P3) -- Print head 0 MCU"
	echo "                       / (P4) -- Print head 1 MCU"
	echo "   USB0 -- USB HUB0 --("
	echo "  /                    \ (P2) -- Print head 2 MCU"
	echo "SOC                     \(P1) -- Print head 3 MCU"
	echo "  \\"
	echo "   USB1 -- USB HUB1 --(P4)-- Main MCU"
}

upgrade()
{
	unit=$1
	firmware="$2"
	option=$2

	if [ x"$firmware" == x"" ] ; then
		echo "Parameters incomplete, please check."
		safe_exit 1
	fi
	if [ x"$option" != x"--check" -a x"$option" != x"--force" ] ; then
		if [ ! -f "$firmware" ] ; then
			echo "File $firmware does not exist, please check and retry."
			safe_exit 1
		fi
	fi

	case "$unit" in
		all)
			NOTIFICATION_ENABLE="Yes"
			cleanup_by_index_range "$LOG_FILE_DIR" "$MAX_LOG_COUNT"
			log_file_path=$(get_log_file_path $LOG_FILE_DIR $LOG_FILE_SUFFIX)
			[ -f "$log_file_path" ] && rm -f "$log_file_path"
			exec > >(tee "$log_file_path") 2>&1
			show_status
			additional_operations_before_active
			upgrade_all "$firmware"
			;;
		soc)
			upgrade_soc "$firmware"
			;;
		mcu0)
			upgrade_main_mcu "$firmware"
			;;
		head0|head1|head2|head3)
			upgrade_head_mcu $unit "$firmware"
			;;
		headall)
			upgrade_head_mcu head0 "$firmware"
			upgrade_head_mcu head1 "$firmware"
			upgrade_head_mcu head2 "$firmware"
			upgrade_head_mcu head3 "$firmware"
			;;
		*)
			echo "Parameter <which unit> error, please enter '$PROG_NAME help' to view help information."
			safe_exit 1
			;;
	esac
}

usage()
{
	echo "usage: $PROG_NAME <command> [<which unit> <firmware path | option>]"
	echo "command:"
	echo "  help           Display this help information"
	echo "  check          Check whether the MCU version matches"
	echo "  check-restore  Check whether the MCU version matches and restore"
	echo "  show-status    Display SOC & MCU status and version"
	echo "  show-topo      Display USB connection topology information"
	echo "  upgrade        Upgrade SOC/MCU firmware"
	echo
	echo "which unit:"
	echo "  all            Main processor and all MCU"
	echo "  soc            Main processor"
	echo "  mcu0           Main MCU"
	echo "  head0          Print head 0 MCU"
	echo "  head1          Print head 1 MCU"
	echo "  head2          Print head 2 MCU"
	echo "  head3          Print head 3 MCU"
	echo "  headall        All print head MCU"
	echo
	echo "When unit is not soc or all, you can specify a firmware path, or"
	echo "use some option. The former upgrade the specified firmware to MCU"
	echo "directly without check version number and MD5 value. The latter"
	echo "uses the default firmware path, and decides what to do depending"
	echo "on option."
	echo "Default path:"
	echo "  Main MCU      : ${MAIN_MCU_FIRMWARE_DEFAULT_PATH}"
	echo "  Print head MCU: ${PRINT_HEAD_MCU_FIRMWARE_DEFAULT_PATH}"
	echo "option:"
	echo "  --check        Check MD5 value and version number. If the version"
	echo "                 number is the same as the current, do not upgrade"
	echo "                 firmware."
	echo "  --force        Check MD5 value, But not version number, upgrade"
	echo "                 the default firmware to the specified MCU."
	echo
	echo "example:"
	echo "  $PROG_NAME show-status"
	echo "  $PROG_NAME check"
	echo "  $PROG_NAME upgrade all /tmp/upgrade.bin"
	echo "  $PROG_NAME upgrade soc /tmp/update.img"
	echo "  $PROG_NAME upgrade mcu0 /tmp/at32f403a.bin"
	echo "  $PROG_NAME upgrade head0 /tmp/at32f415.bin"
	echo "  $PROG_NAME upgrade headall /tmp/at32f415.bin"
	echo "  $PROG_NAME upgrade mcu0 --check"
	echo "  $PROG_NAME upgrade mcu0 --force"
}

if [ -f "$RUNNING_FILE_LOCK" ] ; then
	echo "The upgrade is in progress."
	exit 5
fi
touch "$RUNNING_FILE_LOCK"

case "$1" in
	show-status)
		show_status
		;;
	show-topo)
		show_topo
		;;
	upgrade|up)
		upgrade $2 "$3"
		;;
	check)
		check
		;;
	check-restore)
		check_restore
		;;
	help)
		usage
		;;
	*)
		usage
		;;
esac

safe_exit 0
