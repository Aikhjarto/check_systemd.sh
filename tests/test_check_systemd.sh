#!/bin/bash
# Tests for check_systemd.sh with fake systemctl and ssh commands.
# Run: tests/test_check_systemd.sh

CHECK="$(cd "$(dirname "$0")/.." && pwd)/check_systemd.sh"
FAKE_BIN=$(mktemp -d)
trap 'rm -rf "$FAKE_BIN"' EXIT

# systemctl, controlled by FAKE_* variables
cat > "$FAKE_BIN/systemctl" <<'FAKE'
#!/bin/bash
echo "$*" >> "${FAKE_LOG:-/dev/null}"
if [ -n "$FAKE_DOWN" ]; then
	echo "ssh: connect to host x port 22: Connection refused" >&2
	exit 1
fi
case "$*" in
	*show*) echo "FinishTimestampMonotonic=${FAKE_BOOT_USEC-175857123}" ;;
	*list-units*)
		printf '  a.service loaded active running A\n  sshd.service loaded active running OpenSSH\n'
		printf '  foobar.service loaded active running X\n  foo.socket loaded active listening X\n'
		printf '%b' "${FAKE_FAILED:-}" ;;
esac
FAKE
# ssh runs the remote command locally, with the fake systemctl
cat > "$FAKE_BIN/ssh" <<'FAKE'
#!/bin/bash
echo "ssh $*" >> "${FAKE_LOG:-/dev/null}"
if [ -n "$FAKE_SSH_DOWN" ]; then
	echo "ssh: connect to host $5 port 22: Connection timed out" >&2
	exit 255
fi
bash -c "${@: -1}"
FAKE
chmod +x "$FAKE_BIN"/*
export PATH="$FAKE_BIN:$PATH"

FAILURES=0
TESTS=0

# expect NAME EXIT_CODE OUTPUT_REGEX [ENV=VALUE ...] -- [ARGS ...]
expect(){
	local name=$1 code=$2 regex=$3 envs=() out rc
	shift 3
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
	shift
	out=$(env "${envs[@]}" "$CHECK" "$@" 2>&1)
	rc=$?
	TESTS=$((TESTS + 1))
	if [ $rc -ne "$code" ] || ! [[ "$out" =~ $regex ]] || [ "$(wc -l <<< "$out")" -ne 1 ]; then
		FAILURES=$((FAILURES + 1))
		printf 'FAIL %s: exit %s (expected %s)\n     %s\n' "$name" $rc "$code" "$out"
	else
		printf 'ok   %s\n' "$name"
	fi
}

expect "healthy" 0 '^OK - Boot took 175.857s\|count_units=4 startup_time=175.857s;300;600;0 units_failed=0 services_found=0 services_missing=0$' --
expect "failed units, marked with ●" 2 '^CRITICAL - Failed units: b.service c.service, Boot took' \
	'FAKE_FAILED=● b.service loaded failed failed B\n× c.service loaded failed failed C\n' --
expect "failed units are counted" 2 'count_units=6 startup_time=[^ ]* units_failed=2 ' \
	'FAKE_FAILED=● b.service loaded failed failed B\n× c.service loaded failed failed C\n' --
expect "boot time above -w" 1 '^WARNING - Boot time 400.000s exceeded 300s\|' FAKE_BOOT_USEC=400000000 --
expect "boot time above -c names -c" 2 '^CRITICAL - Boot time 700.000s exceeded 600s\|' FAKE_BOOT_USEC=700000000 --
expect "boot time is not cut off after a day" 2 'startup_time=90000.000s;' FAKE_BOOT_USEC=90000000000 --
expect "still booting" 3 '^UNKNOWN - Boot has not finished yet\|count_units=4 units_failed=0' FAKE_BOOT_USEC=0 --
expect "still booting with failed units" 2 '^CRITICAL - Failed units: b.service, Boot has not finished yet' \
	FAKE_BOOT_USEC=0 'FAKE_FAILED=● b.service loaded failed failed B\n' --
expect "required services running" 0 '^OK - .*services_found=2 services_missing=0$' -- -a sshd -a a.service
expect "required service missing" 2 '^CRITICAL - Missing services: nginx.service, Boot took' -- -a sshd -a nginx
expect "-a is not a prefix" 2 'Missing services: foo.service' -- -a foo
expect "-a is not a regular expression" 2 'Missing services: ss.d.service' -- -a ss.d
expect "-a only counts services" 2 'Missing services: foo.socket.service' -- -a foo.socket
expect "systemctl -H fails" 3 '^UNKNOWN - cannot query systemd on x: ssh: connect to host x port 22: Connection refused$' FAKE_DOWN=1 -- -H x
expect "ssh fails" 3 '^UNKNOWN - cannot query systemd on x: ssh: connect to host .* Connection timed out$' FAKE_SSH_DOWN=1 -- -H x -s
expect "ssh" 0 '^OK - Boot took 175.857s' -- -H monitor@x -s
expect "invalid -w" 3 "^UNKNOWN - -w, -c and -t take a number of seconds, not 'abc'$" -- -w abc
expect "decimal -c" 3 "^UNKNOWN - .* not '1.5'$" -- -c 1.5

# commands the check runs
LOG=$(mktemp)
FAKE_LOG=$LOG "$CHECK" >/dev/null
TESTS=$((TESTS + 1))
if grep -q -- '-H' "$LOG"; then
	FAILURES=$((FAILURES + 1)); echo "FAIL without -H, systemd is queried locally: $(cat "$LOG")"
else
	echo "ok   without -H, systemd is queried locally"
fi
: > "$LOG"
FAKE_LOG=$LOG "$CHECK" -H x -s -t 5 >/dev/null
TESTS=$((TESTS + 1))
if [ "$(grep -c '^ssh ' "$LOG")" -eq 1 ] && grep -q -- '-o BatchMode=yes -o ConnectTimeout=5 x ' "$LOG"; then
	echo "ok   -s uses one non-interactive ssh connection"
else
	FAILURES=$((FAILURES + 1)); echo "FAIL -s uses one non-interactive ssh connection: $(cat "$LOG")"
fi
rm -f "$LOG"

# usage errors: UNKNOWN, the first line names the problem
for ARGS in "-x" "-w"; do
	TESTS=$((TESTS + 1))
	OUT=$("$CHECK" $ARGS 2>&1); RC=$?
	if [ $RC -eq 3 ] && [[ "$(head -n 1 <<< "$OUT")" == "UNKNOWN - "* ]]; then
		echo "ok   usage error $ARGS"
	else
		FAILURES=$((FAILURES + 1)); echo "FAIL usage error $ARGS: exit $RC: $(head -n 1 <<< "$OUT")"
	fi
done

echo "$TESTS tests, $FAILURES failures"
[ $FAILURES -eq 0 ]
