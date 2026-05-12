#!/bin/bash

MAX_LOG_COUNT=50

cleanup_by_index_range()
{
	local log_dir="$1"
	local max_count="$2"

	index_file="$log_dir/index"
	if [ ! -f "$index_file" ] ; then
		return
	else
		current_index=$(cat "$index_file")
	fi

	local min_index_to_keep=$((current_index - max_count + 1))

	local log_files=$(ls -1 "$log_dir"/*.log 2>/dev/null)
	if [ -n "$log_files" ] ; then
		echo "$log_files" | while read log_file ; do
			local filename=$(basename "$log_file")
			if [[ "$filename" =~ ^([0-9]+)_ ]]; then
				local file_index="${BASH_REMATCH[1]}"
				if [[ "$file_index" =~ ^[0-9]+$ ]]; then
					if [ "$file_index" -lt "$min_index_to_keep" ]; then
						rm -f "$log_file"
					fi
				fi
			fi
		done
	fi
}

get_log_file_path()
{
	local dir=$1
	local suffix=$2
	mkdir -p "$dir"

	index_file="$dir/index"
	if [ ! -f "$index_file" ] ; then
		echo "0" > "$index_file"
	fi

	current_index=$(cat "$index_file")

	timestamp=$(date +"%Y%m%d%H%M%S")
	log_filename="${current_index}_${timestamp}_${suffix}"
	log_filepath="$dir/$log_filename"

	next_index=$((current_index + 1))
	echo "$next_index" > "$index_file"

	echo "$log_filepath"
}
