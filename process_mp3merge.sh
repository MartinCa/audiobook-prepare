#!/bin/bash

mp3mergedir="/input/"
untaggeddir="/output/"
faileddir="/failed/"
ebookfilesdir="/ebookfiles/"
logfile="/config/processing.log"
m4bext=".m4b"
logext=".log"
internaluntaggeddir="/untagged/"

cd "$mp3mergedir"

touch -a "$logfile"
mkdir -p "$mp3mergedir"
mkdir -p "$untaggeddir"
mkdir -p "$faileddir"
mkdir -p "$ebookfilesdir"

# CPU Cores used for m4b-tool
if [ -z "$CPU_CORES" ]; then
	echo "Using all CPU cores as CPU_CORES ENV not set."
	CPUcores=$(nproc --all)
else
	echo "Using $CPU_CORES CPU cores as defined."
	CPUcores="$CPU_CORES"
fi

# Run interval
if [ -z "$SLEEPTIME" ]; then
	echo "Using standard 5 min sleep time."
	sleeptime=5m
else
	echo "Using $SLEEPTIME sleep time."
	sleeptime="$SLEEPTIME"
fi

keep_running=1

is_media_file() {
	if [ ! -f "$1" ]; then
		return 1
	fi

	case "${1: -4}" in
	.m4b | .mp3 | .mp4 | .m4a | .ogg | .aac | .wma)
		return 0
		;;
	*)
		return 1
		;;
	esac

	return 1
}

handle_m4btool_output() {
	if [ "$output" ]; then
		# m4b-tool only outputs errors so any output is indication of an error
		logerror="$output"
		cmdresult=99
	else
		if [ -f "$destdir$logfilename" ] || [ ! -f "$destdir$m4bfilename" ]; then
			if [ -f "$destdir$logfilename" ]; then
				# If there is a logfile in the output dir that indicates an error
				chmod a=,a+rwX "$destdir$logfilename"
				logerror=cat "$destdir$logfilename"
			else
				# If output file does not exist something must have gone wrong
				logerror="Output file '$m4bfilename' missing"
			fi
			cmdresult=99
		else
			echo "  Setting permissions and deleting temporary files"
			chmod -R a=,a+rwX "$destdir"

			chaptersfile="$destdir$filename_excl_ext".chapters.txt
			if [ -f "$chaptersfile" ]; then
				rm $chaptersfile
			fi
			tmpfilesdir="$destdir$filename_excl_ext"-tmpfiles
			if [ -d "$tmpfilesdir" ]; then
				rm "$tmpfilesdir" -d
			fi

			cmdresult=0
		fi
	fi

	if [ $cmdresult != 0 ]; then
		echo "  Cleaning up failed output"
		if [ -f "$destdir$logfilename" ]; then
			rm "$destdir$logfilename"
		fi
		if [ -f "$destdir$m4bfilename" ]; then
			rm "$destdir$m4bfilename"
			rm "$destdir" -d
		fi
	fi
}

while [ $keep_running == 1 ]; do
	dir_content=*

	for dir_item in $dir_content; do
		is_media_file "$dir_item"
		dir_item_is_mediafile=$?

		if [ -d "$dir_item" ] || [ $dir_item_is_mediafile == 0 ]; then
			cmdresult=1
			action="NONE"
			logerror=""
			echo "Processing $dir_item"

			full_source_path="$mp3mergedir$dir_item"
			destdir="$untaggeddir$dir_item/"

			if [ $dir_item_is_mediafile == 0 ]; then
				filename_excl_ext=${dir_item::-4}
				destdir="$untaggeddir$filename_excl_ext/"

				if [ "${dir_item: -4}" == ".m4b" ]; then
					# Separate m4b file in root, move straight to untagged for tagging
					action="MOVE"
					echo "  Moving single m4b file '$full_source_path' to '$destdir'"
					mkdir -p "$destdir"
					logerror=$(mv "$full_source_path" "$destdir" 2>&1)
					cmdresult=$?
				else
					# Separate non m4b file in root, convert to m4b

					m4bfilename="$filename_excl_ext$m4bext"
					logfilename="$filename_excl_ext$logext"

					action="MERGE"
					echo "  Converting single media file '$full_source_path' to '$destdir$m4bfilename'"

					if [ -f "$destdir$m4bfilename" ]; then
						logerror="Destination file '$destdir$m4bfilename' already exists"
						cmdresult=99
					else
						mkdir -p "$destdir"

						echo "  Sampling bitrate of $full_source_path"
						bitrate=$(ffprobe -hide_banner -loglevel 0 -of flat -i "$full_source_path" -select_streams a -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1)
						echo "  Detected bitrate of $bitrate"

						output=$(m4b-tool-pre merge "$full_source_path" -n --audio-codec=libfdk_aac --audio-bitrate="$bitrate" --skip-cover --use-filenames-as-chapters --jobs="$CPUcores" --output-file="$destdir$m4bfilename" --logfile="$destdir$logfilename" 2>&1)

						handle_m4btool_output
					fi
				fi
			else
				# Directory
				numberofm4bfiles=$(find "$dir_item" -type f -name '*.m4b' | wc -l)

				if [[ $numberofm4bfiles == 1 ]]; then
					# Only 1 m4b file so we copy dir straight to untagged for tagging
					action="COPY"
					echo "  Copying single m4b file in '$full_source_path' to '$destdir'"
					mkdir -p "$destdir"
					logerror=$(cp "$full_source_path"/*.m4b "$destdir" 2>&1)
					cmdresult=$?
				else
					# We have either 0 or more than 1 m4b file so we have to merge the files.
					# Merged m4b file is output to untagged.
					action="MERGE"

					filename_excl_ext=$dir_item
					m4bfilename="$filename_excl_ext$m4bext"
					logfilename="$filename_excl_ext$logext"

					echo "  Merging $dir_item to $destdir$m4bfilename"

					if [ -f "$destdir$m4bfilename" ]; then
						logerror="Destination file '$destdir$m4bfilename' already exists"
						cmdresult=99
					else
						mkdir -p "$destdir"

						samplefile=$(find "$dir_item" -maxdepth 1 -mindepth 1 -type f \( -name '*.mp3' -o -name '*.m4b' -o -name '*.mp4' -o -name '*.m4a' -o -name '*.ogg' -o -name '*.aac' -o -name '*.wma' \) | head -n 1)

						if [ -z "$samplefile" ]; then
							bitrate=""
						else
							echo "  Sampling bitrate of $samplefile"
							bitrate=$(ffprobe -hide_banner -loglevel 0 -of flat -i "$mp3mergedir$samplefile" -select_streams a -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1)
							echo "  Detected bitrate of $bitrate"
						fi

						output=$(m4b-tool-pre merge "$full_source_path" -n --audio-codec=libfdk_aac --audio-bitrate="$bitrate" --skip-cover --use-filenames-as-chapters --jobs="$CPUcores" --output-file="$destdir$m4bfilename" --logfile="$destdir$logfilename" 2>&1)

						handle_m4btool_output
					fi
				fi

				# Move ebook files
				numberofebookfiles=$(find "$dir_item" -type f \( -name "*.mobi" -o -name "*.pdf" -o -name "*.epub" -o -name "*.azw" -o -name "*.azw3" \) | wc -l)

				if [[ $numberofebookfiles > 0 ]]; then
					mkdir -p "$ebookfilesdir$dir_item"
					find "$dir_item" -type f \( -name "*.mobi" -o -name "*.pdf" -o -name "*.epub" -o -name "*.azw" -o -name "*.azw3" \) -exec cp '{}' "$ebookfilesdir"'{}' \; -exec echo "  Moved ebook file to $ebookfilesdir"'{}' \;
					echo "$(date -I'seconds') MOVED Ebook files for $dir_item" >>"$logfile"
				fi

			fi

			if [ $cmdresult == 0 ]; then
				echo "  Processing succeeded"
				if [ -d "$full_source_path" ]; then
					rm "$full_source_path" -r
				else
					rm "$full_source_path"
				fi
				echo "$(date -I'seconds') SUCCESS $action $dir_item" >>"$logfile"
			else
				echo "  ERROR: Processing failed: $logerror"
				mv "$full_source_path" "$faileddir"
				echo "$(date -I'seconds') FAILED $action $dir_item: $logerror" >>"$logfile"
			fi
		else
			echo "Ignored $dir_item"
		fi
		echo ""
	done

	if [ $MONITOR_DIR != 1 ]; then
		keep_running=0
	else
		echo "Done for now, sleeping for $sleeptime"
		sleep $sleeptime
	fi
done
