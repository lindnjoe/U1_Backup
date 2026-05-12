#!/bin/sh

# usage
# sysinfoCollection.sh yes /tmp/collection.tar.gz

# exit code
# 0    successful
# 1    copy and verification failed when copy to the USB drive
# 2    copy failed, but it wasn't to the USB drive
# 3    copy failed when using an unencrypted method (obsolete)
# 4    the USB drive is not mounted
# 5    the USB drive is mounted as read-only

ENCRYPTION=${1:-"yes"}
TARGET_FILE=${2:-"/userdata/collection.tar.gz"}
INCLUDE_DETECT_RESULT=${3:-"no"}

COLLECTION_DIR="/userdata/.tmp_sysinfo"
BASIC_INFO_DIR=${COLLECTION_DIR}/basic
RESOURCE_INFO_DIR=${COLLECTION_DIR}/resource
LOG_INFO_DIR=${COLLECTION_DIR}/log
CONFIG_INFO_DIR=${COLLECTION_DIR}/config
NETWORK_INFO_DIR=${COLLECTION_DIR}/network
MOTION_CONTROL_SPECIAL_INFO_DIR=${COLLECTION_DIR}/motion_control_special
MPT_INFO_DIR=${COLLECTION_DIR}/mpt
COREDUMP_INFO_DIR=${COLLECTION_DIR}/coredump
DETECT_RESULT_INFO_DIR=${COLLECTION_DIR}/detect_result

# Load the log common function
LOG_UTILS_SCRIPT="/home/lava/bin/log_utils.sh"
[ -f "$LOG_UTILS_SCRIPT" ] && source "$LOG_UTILS_SCRIPT"

LOG_FILE_DIR="/home/lava/printer_data/collection"
LOG_FILE_SUFFIX="sysinfo_collection.log"
LOG_FILE_MAX_COUNT=10
LOG_PREFIX="[COL]"

MAX_RETRIES_IF_COPY_TO_UDISK=5

basic_info_collection()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collect basic information"
	mkdir -p ${BASIC_INFO_DIR}
	uptime -p > ${BASIC_INFO_DIR}/uptime.txt
	cat /proc/uptime > ${BASIC_INFO_DIR}/proc_uptime.txt
	date -R > ${BASIC_INFO_DIR}/date.txt
	printenv > ${BASIC_INFO_DIR}/printenv.txt
	cat /proc/cmdline > ${BASIC_INFO_DIR}/proc_cmdline.txt
	cp -f /etc/FULLVERSION ${BASIC_INFO_DIR}/FULLVERSION
	/home/lava/bin/hwver.sh > ${BASIC_INFO_DIR}/hwver.txt
	/home/lava/bin/systemUpgrade.sh show-status > ${BASIC_INFO_DIR}/systemUpgrade_show_status.txt
	[ -f "/tmp/.serial_number" ] && cp -f /tmp/.serial_number ${BASIC_INFO_DIR}/serial_number.txt
	[ -f "/tmp/.product_code" ] && cp -f /tmp/.product_code ${BASIC_INFO_DIR}/product_code.txt
}

resource_info_collection()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collect resource information"
	mkdir -p ${RESOURCE_INFO_DIR}
	cat /proc/meminfo > ${RESOURCE_INFO_DIR}/meminfo.txt
	ps aux > ${RESOURCE_INFO_DIR}/ps.txt
	lsof -P > ${RESOURCE_INFO_DIR}/lsof.txt
	mpstat -P ALL 1 2 > ${RESOURCE_INFO_DIR}/mpstat.txt
	iostat -x > ${RESOURCE_INFO_DIR}/iostat.txt
	cat /proc/interrupts > ${RESOURCE_INFO_DIR}/proc_interrupts.txt
	mount > ${RESOURCE_INFO_DIR}/mount.txt
	df -h > ${RESOURCE_INFO_DIR}/df.txt
	lsmod > ${RESOURCE_INFO_DIR}/lsmod.txt
	lsusb > ${RESOURCE_INFO_DIR}/lsusb.txt
	lsusb -t > ${RESOURCE_INFO_DIR}/lsusb_t.txt
	lsusb -v > ${RESOURCE_INFO_DIR}/lsusb_v.txt
}

log_info_collection()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collect log information"
	mkdir -p ${LOG_INFO_DIR}
	dmesg > ${LOG_INFO_DIR}/dmesg.txt
	tar zcvf ${LOG_INFO_DIR}/var_log.tar.gz -C /var/log . || true
	tar zcvf ${LOG_INFO_DIR}/printer_data_logs.tar.gz -C /home/lava/printer_data/logs . || true
	[ -d "/home/lava/printer_data/ota" ] && tar zcvf ${LOG_INFO_DIR}/ota_logs.tar.gz -C /home/lava/printer_data/ota . || true
	[ -d "/home/lava/printer_data/collection" ] && tar zcvf ${LOG_INFO_DIR}/collection_logs.tar.gz -C /home/lava/printer_data/collection . || true
}

config_info_collection()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collect config information"
	mkdir -p ${CONFIG_INFO_DIR}
	tar zcvf ${CONFIG_INFO_DIR}/printer_data_config.tar.gz -C /home/lava/printer_data/config . || true
	tar zcvf ${CONFIG_INFO_DIR}/printer_data_mqtt.tar.gz -C /home/lava/printer_data/mqtt . || true
	[ -d "/home/lava/printer_data/klippy" ] && tar zcvf ${CONFIG_INFO_DIR}/printer_data_klippy.tar.gz -C /home/lava/printer_data/klippy . || true
	[ -f "/home/lava/printer_data/.fluidd" ] && cp -f /home/lava/printer_data/.fluidd ${CONFIG_INFO_DIR}/.fluidd || true
}

network_collection()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collect network information"
	mkdir -p ${NETWORK_INFO_DIR}
	ifconfig -a > ${NETWORK_INFO_DIR}/ifconfig.txt
	wpa_cli status > ${NETWORK_INFO_DIR}/wpa_cli_status.txt
	iw dev wlan0 link > ${NETWORK_INFO_DIR}/iw_dev_wlan0_link.txt
	iw dev wlan0 info > ${NETWORK_INFO_DIR}/iw_dev_wlan0_info.txt
	wifi-compatible.sh get > ${NETWORK_INFO_DIR}/wifi-compatible.txt
	route -n > ${NETWORK_INFO_DIR}/route.txt
	netstat -an > ${NETWORK_INFO_DIR}/netstat.txt
	cat /proc/net/dev > ${NETWORK_INFO_DIR}/proc_net_dev.txt
	[ -f "/tmp/dnsmasq.servers.upstream" ] && cat /tmp/dnsmasq.servers.upstream > ${NETWORK_INFO_DIR}/tmp_dnsmasq.servers.upstream.txt
	ping 8.8.8.8 -c 4 > ${NETWORK_INFO_DIR}/ping_8_8_8_8.txt
	ping id.snapmaker.com -c 4 > ${NETWORK_INFO_DIR}/ping_id.snapmaker.com.txt
	ping api.snapmaker.cn -c 4 > ${NETWORK_INFO_DIR}/ping_api.snapmaker.cn.txt
	ping s3.amazonaws.com -c 4 > ${NETWORK_INFO_DIR}/ping_s3.amazonaws.com.txt
	ping s3.us-east-1.amazonaws.com -c 4 > ${NETWORK_INFO_DIR}/ping_s3.us-east-1.amazonaws.com.txt
	ping s3.cn-north-1.amazonaws.com.cn -c 4 > ${NETWORK_INFO_DIR}/ping_s3.cn-north-1.amazonaws.com.cn.txt
	nslookup id.snapmaker.com > ${NETWORK_INFO_DIR}/nslookup_id.snapmaker.com.txt
	nslookup api.snapmaker.cn > ${NETWORK_INFO_DIR}/nslookup_api.snapmaker.cn.txt
	nslookup s3.amazonaws.com > ${NETWORK_INFO_DIR}/nslookup_s3.amazonaws.com.txt
	nslookup s3.us-east-1.amazonaws.com > ${NETWORK_INFO_DIR}/nslookup_s3.us-east-1.amazonaws.com.txt
	nslookup s3.cn-north-1.amazonaws.com.cn > ${NETWORK_INFO_DIR}/nslookup_s3.cn-north-1.amazonaws.com.cn.txt
}

motion_control_special_collection()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collect motion control special information"
	mkdir -p ${MOTION_CONTROL_SPECIAL_INFO_DIR}
	[ -d "/userdata/gcodes/calibration_data" ] && tar zcvf ${MOTION_CONTROL_SPECIAL_INFO_DIR}/calibration_data.tar.gz -C /userdata/gcodes/calibration_data . || true
	[ -d "/userdata/gcodes/shaper_calibrate" ] && tar zcvf ${MOTION_CONTROL_SPECIAL_INFO_DIR}/shaper_calibrate.tar.gz -C /userdata/gcodes/shaper_calibrate . || true
	[ -d "/userdata/gcodes/frequency_data" ] && tar zcvf ${MOTION_CONTROL_SPECIAL_INFO_DIR}/frequency_data.tar.gz -C /userdata/gcodes/frequency_data . || true
}


mpt_collection()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collect MPT files"
	mkdir -p ${MPT_INFO_DIR}
	tar zcvf ${MPT_INFO_DIR}/mpt.tar.gz -C /home/lava/printer_data/backup . || true
	[ -d "/userdata/factory" ] && tar zcvf ${MPT_INFO_DIR}/userdata_factory.tar.gz -C /userdata/factory . || true
}

coredump_collection()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collect coredump files"
	mkdir -p ${COREDUMP_INFO_DIR}
	[ -d "/userdata/.coredump" ] && tar zcvf ${COREDUMP_INFO_DIR}/coredump.tar.gz -C /userdata/.coredump . || true
}

detect_result_collection()
{
	if [ x"$INCLUDE_DETECT_RESULT" != x"no" ] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collect detect result files"
		mkdir -p ${DETECT_RESULT_INFO_DIR}
		[ -d "/userdata/.tmp_detect_result" ] && tar zcvf ${DETECT_RESULT_INFO_DIR}/detect_result.tar.gz -C /userdata/.tmp_detect_result . || true
	else
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: DO NOT collect detect result files"
	fi
}

safe_exit()
{
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Safe exit $1"
	rm -rf ${COLLECTION_DIR}
	sync
	exit $1
}

check_if_udisk_file()
{
	filepath="$1"
	# if copy to udisk
	if [[ "${filepath}" == *"udisk"* ]] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: The target file is on the USB drive."
		# display udisk mount information
		mount_info=$(mount | grep udisk)
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: udisk mount information: ${mount_info}"
		if [ x"${mount_info}" == x"" ] ; then
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: The USB drive is not mounted."
			safe_exit 4
		fi
		# check udisk mount information
		if echo "$mount_info" | grep -q "ro,"; then
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: The USB drive is mounted in read-only mode."
			safe_exit 5
		fi
	fi
}

main()
{
	cleanup_by_index_range "$LOG_FILE_DIR" "$LOG_FILE_MAX_COUNT"
	log_file_path=$(get_log_file_path $LOG_FILE_DIR $LOG_FILE_SUFFIX)
	[ -f "$log_file_path" ] && rm -f "$log_file_path"
	exec > >(tee "$log_file_path") 2>&1

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: ENCRYPTION is ${ENCRYPTION}"
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: TARGET_FILE is ${TARGET_FILE}"
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: INCLUDE_DETECT_RESULT is ${INCLUDE_DETECT_RESULT}"

	# if copy to udisk
	check_if_udisk_file ${TARGET_FILE}

	basic_info_collection
	resource_info_collection
	config_info_collection
	network_collection
	motion_control_special_collection
	mpt_collection
	coredump_collection
	detect_result_collection
	log_info_collection
	sync
	echo "${LOG_PREFIX} ${FUNCNAME[0]}: Collection completed"

	cd ${COLLECTION_DIR}/ && tar zcvf sysinfo.tar.gz * && cd -

	if [ x"$ENCRYPTION" != x"no" ] ; then
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: Prepare for encryption."
		openssl rand -hex 64 > /tmp/aes_key.txt
		openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -in ${COLLECTION_DIR}/sysinfo.tar.gz -out ${COLLECTION_DIR}/content.enc -pass file:/tmp/aes_key.txt
		openssl pkeyutl -encrypt -pubin -inkey /etc/collection/public_key.pem -in /tmp/aes_key.txt -out ${COLLECTION_DIR}/key.enc

		echo "${LOG_PREFIX} ${FUNCNAME[0]}: Packaging encrypted files."
		cd ${COLLECTION_DIR}/ && tar zcvf collection.tar.gz content.enc key.enc && cd -
		rm -f /tmp/aes_key.txt

		SOURCE_FILE="${COLLECTION_DIR}/collection.tar.gz"
	else
		SOURCE_FILE="${COLLECTION_DIR}/sysinfo.tar.gz"
	fi

	# if copy to udisk
	if [[ "${TARGET_FILE}" == *"udisk"* ]] ; then
		retry_count=0
		success=0
		source_md5=$(md5sum "${COLLECTION_DIR}/collection.tar.gz" | awk '{print $1}')
		echo "${LOG_PREFIX} ${FUNCNAME[0]}: Source file MD5 is ${source_md5}"

		while [ $retry_count -lt $MAX_RETRIES_IF_COPY_TO_UDISK ] && [ $success -eq 0 ] ; do
			# do check before copying file
			check_if_udisk_file ${TARGET_FILE}
			cp -f "${SOURCE_FILE}" "${TARGET_FILE}"
			if [ $? -eq 0 ] ; then
				target_md5=$(md5sum "${TARGET_FILE}" | awk '{print $1}')
				echo "${LOG_PREFIX} ${FUNCNAME[0]}: Target file MD5 is ${target_md5}"

				if [ "$source_md5" == "$target_md5" ] ; then
					success=1
				else
					retry_count=$((retry_count + 1))
					if [ $retry_count -lt $MAX_RETRIES_IF_COPY_TO_UDISK ] ; then
						sleep 1
					fi
				fi
			else
				retry_count=$((retry_count + 1))
				if [ $retry_count -lt $MAX_RETRIES_IF_COPY_TO_UDISK ] ; then
					sleep 1
				fi
			fi
		done

		if [ $success -eq 0 ] ; then
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: After ${MAX_RETRIES_IF_COPY_TO_UDISK} attempts, it finally failed."
			safe_exit 1
		else
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: Copy and verification completed."
		fi
	else
		cp -f "${SOURCE_FILE}" "${TARGET_FILE}"
		if [ $? -eq 0 ]; then
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: Copy successful."
		else
			echo "${LOG_PREFIX} ${FUNCNAME[0]}: Copy filed."
			safe_exit 2
		fi
	fi

	echo "${LOG_PREFIX} ${FUNCNAME[0]}: ${TARGET_FILE} is ready."

	rm -rf ${COLLECTION_DIR}
	sync
}


main
exit 0
