#!/bin/bash
# Copyright (C) Thomas Wagner <wagner-thomas@gmx.at>
# SPDX-License-Identifier: GPL-2.0-or-later

set -o errexit


NAG_OK=0
NAG_WARN=1
NAG_CRIT=2
NAG_UNKNOWN=3

FAILED_UNITS_STR=""
NUM_FAILED=0
STATUS_STR=OK
RET_VAL=$NAG_OK
REMOTE_HOST='localhost'
BOOT_TIME_WARN_SEC=300
BOOT_TIME_CRIT_SEC=600
BOOT_TIME_STR=""

USE_SSH=""

trap "echo 'UNKNOWN - '; exit $NAG_UNKNOWN" EXIT

print_usage(){
cat <<EOF
This script checks status of systemd and reports boot time as well as failed services.
 Usage: check_systemd -H hostname -c TIME -w TIME [-s] [
-H [USER@]HOSTNAME      Connection information, where HOSTNAME can be an IP adress too
-w T                    If boot took longer than T seconds (no decimal notation allowed), status is reported as WARNING.
-c T                    If boot took longer than T seconds (no decimal notation allowed), status is reported as CRITICAL.
-s                      Use ssh to connect instead of -H option from systemd, since -H can trigger errors like 'Failed to send message: Transport endpoint is not connected' in some versions of systemd.
-a servicename          Name of units that need to be running. Can be given multiple times. "servicename" is without the suffix ".service". If any service given with -a is not running, status is reported as CRITICAL.
EOF
}


while getopts "H:w:c:sa:h" opt; do
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
                a)
                        multi+=("$OPTARG")
                        ;;
                h)
                        print_usage
                        trap "" EXIT
                        exit $NAG_UNKNOWN
                        ;;
                ?)
                        echo "Invalid options $opt"
                        print_usage
                        trap "" EXIT
                        exit $NAG_UNKNOWN
                        ;;
        esac
done

if [ -n "${USE_SSH}" ]; then
        SYSTEMD_ANALYZE_BIN="ssh ${REMOTE_HOST} systemd-analyze"
        SYSTEMCTL_BIN="ssh ${REMOTE_HOST} systemctl"
else
        SYSTEMD_ANALYZE_BIN="systemd-analyze -H ${REMOTE_HOST}"
        SYSTEMCTL_BIN="systemctl -H ${REMOTE_HOST}"
fi

ANALYZE_STR=$($SYSTEMD_ANALYZE_BIN time --no-pager 2>&1 | head -n 1)

# convert boot time to seconds
# Caution: The systemd timespan for boot time produced by "systemd-analze time" skip the seconds-term is seconds was zero but milliseconds was not, e.g. 01:00.350 is displayed as "1min 350ms"
# So relying on position like that https://stackoverflow.com/a/30826886 does not work reliably
#BOOT_TIME_SEC=$(echo ${ANALYZE_STR} | sed -e 's/^.*= //' -e 's/min//' -e 's/s//' | awk '{print (NF>2?$(NF-2)*3600:0)+(NF>1?$(NF-1)*60:0)+$(NF)}')
# Resort to FinishedTimestampMonotonic from systemctl show which produce time in microseconds as int.
BOOT_TIME_SEC=$(echo $($SYSTEMCTL_BIN show --no-pager | grep -E "^FinishTimestampMonotonic=") | awk -F "=" '{print $2 /1000000}')

# round toward zero since float compares are hard in bash
BOOT_TIME_SEC_ROUND=$(echo $BOOT_TIME_SEC | sed -e 's/\..*$//' -e 's/,.*$//')

# compare boot time to limits
if [ $BOOT_TIME_SEC_ROUND -gt $BOOT_TIME_WARN_SEC ]; then
        BOOT_TIME_STR="Boot time exceeded ${BOOT_TIME_WARN_SEC}s, "
        STATUS_STR=WARNING
        RET_VAL=$NAG_WARN
fi

if [ $BOOT_TIME_SEC_ROUND -gt $BOOT_TIME_CRIT_SEC ]; then
        BOOT_TIME_STR="Boot time exceeded ${BOOT_TIME_WARN_SEC}s, "
        STATUS_STR=CRITICAL
        RET_VAL=$NAG_CRIT
fi

# if something failed with systemd-analyze (e.g. system is not yet booted completely), print error
if [ ! $BOOT_TIME_SEC_ROUND -gt 0 ]; then
        BOOT_TIME_STR=$ANALYZE_STR
        STATUS_STR=UNKNOWN
        RET_VAL=$NAG_UNKNOWN
fi

# get list of failed units
# on some version of systemd, $1 is '●'
RESULT=$($SYSTEMCTL_BIN list-units --failed --full --no-legend --no-pager)
if [[ "${RESULT}" == "●"* ]]; then
        LST_FAILED_UNITS=$(awk '{print $2}' <<< "$RESULT")
else
        LST_FAILED_UNITS=$(awk '{print $1}' <<< "$RESULT")
fi
#>sudo -u nagios systemctl -H debian-xmpp.private.lan list-units --failed --full --no-legend --no-pager
#block-badips-onboot.service loaded failed failed Applies iptables rules to block known IPs doing nasty stuff"
#block-badips-timer.service  loaded failed failed Timer service for running block badips script periodically 

# assemble list of failed units as human readable string
if [ ! -z "$LST_FAILED_UNITS" ]; then
        NUM_FAILED=$(printf '%s\n' $LST_FAILED_UNITS | wc -l)
        STATUS_STR=CRITICAL
        FAILED_UNITS_STR="Failed units: $LST_FAILED_UNITS, "
        RET_VAL=$NAG_CRIT
fi

# get total number of units
NUM_UNITS=$($SYSTEMCTL_BIN list-units --no-pager --no-legend | wc -l)

# get list of running services
RUNNING_SERVICES=$($SYSTEMCTL_BIN list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}')
NUM_F=0
NUM_NF=0
MISSING_SERVICE_STR=""
for val in "${multi[@]}"; do
        if [ ! -z "${val}" ]; then ## check for emptiness, otherwise grep produces an error
                if grep -q ^${val}.service <<<${RUNNING_SERVICES} ; then
        #               echo $val found in ${TMP_FILE}
                        F="$F $val"
                        NUM_F=$((NUM_F + 1))
                else
        #               echo $val NOT found in ${TMP_FILE}
                        NF="$NF $val"
                        NUM_NF=$((NUM_NF + 1))
                        STATUS_STR=CRITICAL
                        RET_VAL=$NAG_CRIT
                        if [ -z "$MISSING_SERVICES_STR" ]; then
                                MISSING_SERVICES_STR="Missing services "
                        fi
                        MISSING_SERVICES_STR="$MISSING_SERVICES_STR${val}.service "
                fi
        fi
done


# assemble output string
# sample output of check_systemd (python reference implementation) 
# |count_units=312 startup_time=175.857;60;120 units_activating=0 units_active=219 units_failed=0 units_inactive=93
echo $STATUS_STR - ${FAILED_UNITS_STR}${MISSING_SERVICES_STR}${BOOT_TIME_STR}${ANALYZE_STR}$PERF_DATA"|count_units=${NUM_UNITS} startup_time=${BOOT_TIME_SEC} units_failed=${NUM_FAILED} services_found=${NUM_F}  services_missing=${NUM_NF}"

# reset trap
trap EXIT
exit $RET_VAL

