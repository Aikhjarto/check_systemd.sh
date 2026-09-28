#!/bin/bash
# Copyright (C) Thomas Wagner <wagner-thomas@gmx.at>
# SPDX-License-Identifier: GPL-2.0-or-later


NAG_OK=0
NAG_WARN=1
NAG_CRIT=2
NAG_UNKNOWN=3

REMOTE_HOST=""
BOOT_TIME_WARN_SEC=300
BOOT_TIME_CRIT_SEC=600
SSH_TIMEOUT=10
USE_SSH=""
REQUIRED_SERVICES=()

print_usage(){
cat <<EOF
This script checks status of systemd and reports boot time as well as failed services.
 Usage: check_systemd.sh [-H [USER@]HOSTNAME] [-s] [-t T] [-w T] [-c T] [-a servicename]...
-H [USER@]HOSTNAME      Connection information, where HOSTNAME can be an IP adress too. Without -H, the local systemd is checked.
-w T                    If boot took longer than T seconds (no decimal notation allowed), status is reported as WARNING (default 300).
-c T                    If boot took longer than T seconds (no decimal notation allowed), status is reported as CRITICAL (default 600).
-s                      Use ssh to connect instead of -H option from systemd, since -H can trigger errors like 'Failed to send message: Transport endpoint is not connected' in some versions of systemd.
-t T                    With -s, give up connecting after T seconds (default 10).
-a servicename          Name of units that need to be running. Can be given multiple times. "servicename" is without the suffix ".service". If any service given with -a is not running, status is reported as CRITICAL.
-h                      Show this help.
EOF
}

# prints the plugin output and exits
# unknown MESSAGE
unknown(){
	echo "UNKNOWN - $1"
	exit $NAG_UNKNOWN
}

is_integer(){
	[[ "$1" =~ ^[0-9]+$ ]]
}


while getopts ":H:w:c:st:a:h" opt; do
	case $opt in
		H)
			REMOTE_HOST=$OPTARG
			;;
		w)
			BOOT_TIME_WARN_SEC=$OPTARG
			;;
		c)
			BOOT_TIME_CRIT_SEC=$OPTARG
			;;
		s)
			USE_SSH="y"
			;;
		t)
			SSH_TIMEOUT=$OPTARG
			;;
		a)
			REQUIRED_SERVICES+=("${OPTARG%.service}")
			;;
		h)
			print_usage
			exit $NAG_UNKNOWN
			;;
		:)
			echo "UNKNOWN - option -$OPTARG needs an argument"
			print_usage
			exit $NAG_UNKNOWN
			;;
		?)
			echo "UNKNOWN - invalid option -$OPTARG"
			print_usage
			exit $NAG_UNKNOWN
			;;
	esac
done

for VALUE in "$BOOT_TIME_WARN_SEC" "$BOOT_TIME_CRIT_SEC" "$SSH_TIMEOUT"; do
	is_integer "$VALUE" || unknown "-w, -c and -t take a number of seconds, not '$VALUE'"
done

if [ -n "$USE_SSH" ] && [ -z "$REMOTE_HOST" ]; then
	REMOTE_HOST=localhost
fi


# query systemd: the time the boot finished, then the loaded units
# with -s, both in one ssh connection
QUERY="systemctl show --no-pager -p FinishTimestampMonotonic && systemctl list-units --no-pager --no-legend --full"
ERR_FILE=$(mktemp) || unknown "cannot create a temporary file"
trap 'rm -f "$ERR_FILE"' EXIT

if [ -n "$USE_SSH" ]; then
	# BatchMode: fail instead of asking for a password or a host key
	OUTPUT=$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$REMOTE_HOST" "$QUERY" 2>"$ERR_FILE")
	RC=$?
elif [ -n "$REMOTE_HOST" ]; then
	OUTPUT=$(systemctl -H "$REMOTE_HOST" show --no-pager -p FinishTimestampMonotonic 2>"$ERR_FILE" &&
		systemctl -H "$REMOTE_HOST" list-units --no-pager --no-legend --full 2>"$ERR_FILE")
	RC=$?
else
	OUTPUT=$(systemctl show --no-pager -p FinishTimestampMonotonic 2>"$ERR_FILE" &&
		systemctl list-units --no-pager --no-legend --full 2>"$ERR_FILE")
	RC=$?
fi

if [ $RC -ne 0 ]; then
	ERROR=$(grep -v '^[[:space:]]*$' "$ERR_FILE" | head -n 1)
	unknown "cannot query systemd${REMOTE_HOST:+ on $REMOTE_HOST}: ${ERROR:-exit code $RC}"
fi


# boot time in microseconds since the kernel started, 0 while still booting
BOOT_TIME_USEC=$(sed -n 's/^FinishTimestampMonotonic=//p' <<< "$OUTPUT" | head -n 1)
is_integer "$BOOT_TIME_USEC" || unknown "cannot read the boot time from '$(head -n 1 <<< "$OUTPUT")'"

# columns: UNIT LOAD ACTIVE SUB DESCRIPTION; failed units may be marked with a leading ●, × or *
UNITS=$(grep -v '^FinishTimestampMonotonic=' <<< "$OUTPUT" | awk 'NF {
	i = ($1 == "●" || $1 == "×" || $1 == "*") ? 2 : 1
	print $i, $(i + 2), $(i + 3)
}')
NUM_UNITS=$(grep -c . <<< "$UNITS")
LST_FAILED_UNITS=$(awk '$2 == "failed" {print $1}' <<< "$UNITS")
NUM_FAILED=$(grep -c . <<< "$LST_FAILED_UNITS")
RUNNING_SERVICES=$(awk '$1 ~ /\.service$/ && $3 == "running" {print $1}' <<< "$UNITS")


STATUS_STR=OK
RET_VAL=$NAG_OK
MESSAGES=()

# raises the state, CRITICAL outranks UNKNOWN outranks WARNING
# raise_state STATE
raise_state(){
	case "$1" in
		$NAG_CRIT) STATUS_STR=CRITICAL; RET_VAL=$NAG_CRIT ;;
		$NAG_UNKNOWN) [ $RET_VAL -ne $NAG_CRIT ] && { STATUS_STR=UNKNOWN; RET_VAL=$NAG_UNKNOWN; } ;;
		$NAG_WARN) [ $RET_VAL -eq $NAG_OK ] && { STATUS_STR=WARNING; RET_VAL=$NAG_WARN; } ;;
	esac
}

if [ "$NUM_FAILED" -gt 0 ]; then
	raise_state $NAG_CRIT
	MESSAGES+=("Failed units: $(tr '\n' ' ' <<< "$LST_FAILED_UNITS" | sed 's/ $//')")
fi

# services given with -a have to be running
NUM_FOUND=0
NUM_MISSING=0
MISSING_SERVICES=""
for SERVICE in "${REQUIRED_SERVICES[@]}"; do
	[ -n "$SERVICE" ] || continue
	if grep -qxF "${SERVICE}.service" <<< "$RUNNING_SERVICES"; then
		NUM_FOUND=$((NUM_FOUND + 1))
	else
		NUM_MISSING=$((NUM_MISSING + 1))
		MISSING_SERVICES="$MISSING_SERVICES ${SERVICE}.service"
	fi
done
if [ $NUM_MISSING -gt 0 ]; then
	raise_state $NAG_CRIT
	MESSAGES+=("Missing services:$MISSING_SERVICES")
fi

# compare boot time to limits
PERF_BOOT=""
if [ "$BOOT_TIME_USEC" -eq 0 ]; then
	raise_state $NAG_UNKNOWN
	MESSAGES+=("Boot has not finished yet")
else
	BOOT_TIME_SEC_ROUND=$((BOOT_TIME_USEC / 1000000))
	BOOT_TIME_SEC=$(LC_ALL=C awk -v usec="$BOOT_TIME_USEC" 'BEGIN { printf "%.3f", usec / 1000000 }')
	if [ $BOOT_TIME_SEC_ROUND -gt $BOOT_TIME_CRIT_SEC ]; then
		raise_state $NAG_CRIT
		MESSAGES+=("Boot time ${BOOT_TIME_SEC}s exceeded ${BOOT_TIME_CRIT_SEC}s")
	elif [ $BOOT_TIME_SEC_ROUND -gt $BOOT_TIME_WARN_SEC ]; then
		raise_state $NAG_WARN
		MESSAGES+=("Boot time ${BOOT_TIME_SEC}s exceeded ${BOOT_TIME_WARN_SEC}s")
	else
		MESSAGES+=("Boot took ${BOOT_TIME_SEC}s")
	fi
	PERF_BOOT=" startup_time=${BOOT_TIME_SEC}s;${BOOT_TIME_WARN_SEC};${BOOT_TIME_CRIT_SEC};0"
fi


# assemble output string
# sample output of check_systemd (python reference implementation)
# |count_units=312 startup_time=175.857;60;120 units_activating=0 units_active=219 units_failed=0 units_inactive=93
MESSAGE=$(printf '%s, ' "${MESSAGES[@]}")
printf '%s - %s|count_units=%s%s units_failed=%s services_found=%s services_missing=%s\n' \
	"$STATUS_STR" "${MESSAGE%, }" "$NUM_UNITS" "$PERF_BOOT" "$NUM_FAILED" "$NUM_FOUND" "$NUM_MISSING"

exit $RET_VAL
