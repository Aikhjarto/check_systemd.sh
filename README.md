# check_systemd.sh

A Nagios/Icinga plugin that checks systemd on a local or remote machine: the
boot time, failed units and services that have to be running.

```sh
check_systemd.sh -H server.example.com -w 300 -c 600
check_systemd.sh -H monitor@server.example.com -s -a sshd -a postfix
```

| Option | Meaning |
|---|---|
| `-H` | `[USER@]HOST` to check (default: localhost) |
| `-w` | WARNING if booting took longer than this many seconds (default: 300) |
| `-c` | CRITICAL if booting took longer than this many seconds (default: 600) |
| `-s` | Connect with `ssh` instead of `systemctl -H`, which fails with "Transport endpoint is not connected" on some systemd versions |
| `-a` | Service, without `.service`, that has to be running; may be repeated |
| `-h` | Show the help |

Any failed unit and any service given with `-a` that is not running is
CRITICAL. The monitoring user needs key based ssh access to the machine.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE).
