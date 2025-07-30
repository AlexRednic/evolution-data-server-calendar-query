#!/bin/bash

# Get today's date in required formats
DATE=$(date -u +%Y%m%d)
TODAY_START="make-time \"${DATE}T000000Z\""
TODAY_END="make-time \"${DATE}T235959Z\""

# Temporary storage
EVENT_LIST=()
UPCOMING_EVENTS=()
PAST_EVENTS=()
ALL_DAY_EVENTS=()

CURRENT_TIME=$(date +"%Y%m%d%H%M%S")

# Function to parse ICS and extract SUMMARY, DTSTART, DTEND
parse_event() {
	local event="$1"
	echo "Parsing event: $event"

	local summary=$(echo "$event" | grep -oP '^SUMMARY[^:]*:\K.*')
	local dtstart=$(echo "$event" | grep -oP '^DTSTART[^:]*:\K.*')
	local dtend=$(echo "$event" | grep -oP '^DTEND[^:]*:\K.*')
	local dtstamp=$(echo "$event" | grep -oP '^DTSTAMP[^:]*:\K.*')
	local tzid=$(echo "$event" | grep -oP 'DTSTART.*TZID=\K[^:]+')
	local recurrent=$(echo "$event" | grep -oP '^RRULE[^:]*:\K.*')

	echo "Parse result - $summary|$dtstart|$dtend|$tzid|$recurrent|$dtstamp"

	local time=""

	if [[ $dtstart =~ T ]]; then
		# Timed event: convert to sortable date
		if [[ -n "$recurrent" ]]; then
			time=$(echo "$dtstart" | grep -oP 'T\K[0-9]{6}')
			dtstart="${DATE}T${time}"

			time=$(echo "$dtend" | grep -oP 'T\K[0-9]{6}')
			dtend="${DATE}T${time}"
		fi
		if [[ -n "$tzid" ]]; then
			# Convert to local timezone
			dtstart=$(convert_date_to_TZ "$dtstart" "$tzid")
			dtend=$(convert_date_to_TZ "$dtend" "$tzid")
		fi

		sortkey=$(echo "$dtstart" | sed 's/T//' | sed 's/Z//')
		echo "Processing result - $sortkey|$summary|$dtstart|$dtend|$dtstamp"

		#Check for duplicates. If same summary is found, and this item is newer then replace with newer one
		local updated=false
		local event_list_length=${#EVENT_LIST[@]}
		for (( i=0; i<${event_list_length}; i++ )); do
			IFS='|' read -r existing_sortkey existing_summary _ _ existing_dtstamp <<<"${EVENT_LIST[i]}"
			if [[ "$existing_summary" == "$summary" ]]; then
				updated=true
				if [[ $dtstamp -gt $existing_dtstamp ]]; then
					EVENT_LIST[i]="$sortkey|$summary|$dtstart|$dtend|$dtstamp"
					return
				fi
			fi
		done
		# Add the event to the list if not updated
		if [ "$updated" = false ]; then
			EVENT_LIST+=("$sortkey|$summary|$dtstart|$dtend|$dtstamp")
		fi
	else
		# All-day event: set time to 00:00:00
		dtstart="${DATE}T000000Z"
		dtend="${DATE}T235959Z"
		# All-day event
		ALL_DAY_EVENTS+=("|$summary|$dtstart|$dtend")
	fi

}

distribute_events() {
	for item in "${EVENT_LIST[@]}"; do
		local IFS
		local endtime

		IFS='|' read -r sortkey summary dtstart dtend dtstamp <<<"$item"
		endtime=$(echo "$dtend" | sed 's/T//' | sed 's/Z//')

		if [[ "$CURRENT_TIME" -gt "$endtime" ]]; then
			PAST_EVENTS+=("$sortkey|$summary|$dtstart|$dtend")
		else
			UPCOMING_EVENTS+=("$sortkey|$summary|$dtstart|$dtend")
		fi

	done
}

convert_date_to_TZ() {
	# Input date in the source timezone (UTC)
	local input_date="$1" # format YYYYMMDDTHHMMSS
	local tzid="$2"       # Timezone ID, e.g., "Europe/Helsinki"

	local formatted_date=$(echo "$input_date" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})$/\1-\2-\3 \4:\5:\6/')

	# Convert the input date to a Unix timestamp in the source timezone
	local timestamp=$(TZ="$tzid" date -d "$formatted_date" +"%s")

	# Convert the timestamp to the target timezone (local timezone)
	local converted_date=$(date -d "@$timestamp" +"%Y%m%dT%H%M%S")

	#echo "$input_date|$tzid|$formatted_date|$timestamp|$converted_date"

	echo "$converted_date"
}

# Step 1: Get UIDs of calendar sources
SOURCE_OUTPUT=$(gdbus call --session \
	--dest org.gnome.evolution.dataserver.Sources5 \
	--object-path /org/gnome/evolution/dataserver/SourceManager \
	--method org.freedesktop.DBus.ObjectManager.GetManagedObjects)

UIDS=($(echo "$SOURCE_OUTPUT" | grep -oP "'UID': <'\K[^']+"))

# Step 2: Iterate through UIDs and get subprocess path
for uid in "${UIDS[@]}"; do
	echo "uid - $uid"
	CAL_RESULT=$(gdbus call --session \
		--dest org.gnome.evolution.dataserver.Calendar8 \
		--object-path /org/gnome/evolution/dataserver/CalendarFactory \
		--method org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar "$uid" 2>/dev/null)
	echo "$CAL_RESULT"

	# Skip if this UID does not return a valid calendar
	[[ $? -ne 0 ]] && continue

	OBJECT_PATH=$(echo "$CAL_RESULT" | grep -oP "'/\K[^']+" | sed 's/^/\//')

	# Step 3: Get events for today
	ICS_RESULT=$(gdbus call --session \
		--dest org.gnome.evolution.dataserver.Calendar8 \
		--object-path "$OBJECT_PATH" \
		--method org.gnome.evolution.dataserver.Calendar.GetObjectList \
		"(occur-in-time-range? ($TODAY_START) ($TODAY_END))")
	echo "$ICS_RESULT" | tr ',' '\n' | sed -e 's/\\r\\n/\n/g'

	# Step 4: Extract each VEVENT block
	VEVENTS=$(echo "$ICS_RESULT" | tr ',' '\n' | sed -e 's/\\r\\n/\n/g')

	# Step 5: Parse and store
	CURRENT_EVENT=""
	while read -r line; do
		if [[ $line == *"BEGIN:VEVENT"* ]]; then
			CURRENT_EVENT=""
		fi
		CURRENT_EVENT+="$line"$'\n'
		if [[ $line == *"END:VEVENT"* ]]; then
			parse_event "$CURRENT_EVENT"
		fi
	done <<<"$VEVENTS"
done

distribute_events

# Step 6: Sort timed events
IFS=$'\n' SORTED_UPCOMING_EVENTS=($(sort <<<"${UPCOMING_EVENTS[*]}"))
unset IFS

IFS=$'\n' SORTED_PAST_EVENTS=($(sort <<<"${PAST_EVENTS[*]}"))
unset IFS

# Step 7: Generate HTML
cat <<EOF >output.html
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <style>
    h2 {
      padding-top: 0;
      margin-top: 0;
    }
    body {
      font-family: Arial, sans-serif;
      background-color: transparent;
      color: #f8f9f9;
      padding: 1em;
      padding-top: 0;
    }
    .event {
      border-bottom: 1px solid #ccc;
      margin-bottom: 0.8em;
      padding-bottom: 0.5em;
    }
    .past {
      color: #888;
    }
    .summary {
      font-size: 1.1em;
      font-weight: bold;
    }
    .time {
      font-size: 0.9em;
    }
    .all-day {
      font-style: italic;
      opacity: 0.8;
    }
    .footer {
      position: fixed;
      bottom: 0;
      color: #888;
      font-size: 0.8em;
    }
  </style>
</head>
<body>
  <h2>Upcoming Appointments</h2>
EOF

for item in "${SORTED_UPCOMING_EVENTS[@]}"; do
	IFS='|' read -r _ summary dtstart dtend <<<"$item"
	start_time=$(echo "$dtstart" | grep -oP 'T\K[0-9]{4}' | sed 's/\(..\)/\1:/')
	end_time=$(echo "$dtend" | grep -oP 'T\K[0-9]{4}' | sed 's/\(..\)/\1:/')
	cat <<EOF >>output.html
  <div class="event">
      <div class="summary">$summary</div>
      <div class="time">$start_time - $end_time</div>
    </div>
EOF
done

for item in "${ALL_DAY_EVENTS[@]}"; do
	IFS='|' read -r _ summary dtstart dtend <<<"$item"
	cat <<EOF >>output.html
  <div class="event all-day">
      <div class="summary">$summary</div>
      <div class="time">All day</div>
  </div>
EOF
done

cat <<EOF >>output.html
  <h2>Past Appointments</h2>
EOF
for item in "${SORTED_PAST_EVENTS[@]}"; do
	IFS='|' read -r _ summary dtstart dtend <<<"$item"
	start_time=$(echo "$dtstart" | grep -oP 'T\K[0-9]{4}' | sed 's/\(..\)/\1:/')
	end_time=$(echo "$dtend" | grep -oP 'T\K[0-9]{4}' | sed 's/\(..\)/\1:/')
	cat <<EOF >>output.html
  <div class="event past">
      <div class="summary">$summary</div>
      <div class="time">$start_time - $end_time</div>
  </div>
EOF
done

cat <<EOF >>output.html
<div class="footer">
  Last update: $(date +"%Y-%m-%d %H:%M:%S")
</div>
</body>
</html>
EOF
