# check_systemd.sh

A Nagios/Icinga plugin that checks systemd on a local or remote machine: the
boot time, failed units and services that have to be running.

```sh
check_systemd.sh -w 300 -c 600
check_systemd.sh -H server.example.com -w 300 -c 600
check_systemd.sh -H monitor@server.example.com -s -a sshd -a postfix
```

```
CRITICAL - Failed units: backup.service, Missing services: postfix.service, Boot took 15.464s|count_units=170 startup_time=15.464s;300;600;0 units_failed=1 services_found=1 services_missing=1
```

| Option | Meaning |
|---|---|
| `-H` | `[USER@]HOST` to check; without it, the local systemd is checked |
| `-w` | WARNING if booting took longer than this many seconds (default: 300) |
| `-c` | CRITICAL if booting took longer than this many seconds (default: 600) |
| `-s` | Connect with `ssh` instead of `systemctl -H`, which fails with "Transport endpoint is not connected" on some systemd versions |
| `-t` | With `-s`, give up connecting after this many seconds (default: 10) |
| `-a` | Service that has to be running, with or without `.service`; may be repeated |
| `-h` | Show the help |

Any failed unit and any service given with `-a` that is not running is
CRITICAL. A machine that has not finished booting is UNKNOWN, as are a
machine that cannot be reached and an invalid command line.

For a remote machine, the monitoring user needs key based ssh access to it.
With `-s`, the check uses a single ssh connection and never asks for a
password or a host key, so an unknown host key fails the check instead of
hanging it.

## Tests

```sh
tests/test_check_systemd.sh
```

runs the check against fake `systemctl` and `ssh` commands.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
