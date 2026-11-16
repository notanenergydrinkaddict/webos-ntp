# webos-ntp
Non blocking WebOS NTP script

### Usage

- Telnet or SSH into your TV
- Write [999-ntp-main.sh](/999-ntp-main.sh) into `/var/lib/webosbrew/init.d`
- Mark it executable
- ```
  chmod +x /var/lib/webosbrew/init.d/999-ntp-main.sh
  ```
- in Homebrew Channel, Click on Restart TV, you should see `Time set OK via NTP 0.pool.ntp.org (2026-11-16 20:11:42)` after 10-20 seconds, it will abort after 20 attempts if failed.
- **Optional**
  - Run it with `BLOCKING=1` to see output in terminal, or reboot to check startup behavior.
    - Example notification (must not be on screensaver to see): `Time set OK via NTP 0.pool.ntp.org (2026-11-16 20:11:42)`
    - Example terminal output:
    - ```
      ~ # BLOCKING=1 /var/lib/webosbrew/init.d/999-ntp-main.sh
      2024-10-22 01:11:06 [6581] mode: BLOCKING=1 DRY_RUN=0 METHODS=[ntpd ntpdate node http] attempts=1
      2024-10-22 01:11:06 [6581] tools: ntpd=NO ntpdate=NO node=/bin/node nc=yes nslookup=yes timeout=yes luna-send=yes
      2024-10-22 01:11:06 [6581] clock at start: Tue Oct 22 01:11:06 +00 2024
      2024-10-22 01:11:06 [6581] DBG worker started, tools ntpd=NO node=/bin/node
      2024-10-22 01:11:06 [6581] attempt 1/1
      2024-10-22 01:11:06 [6581] DBG attempt 1
      2024-10-22 01:11:06 [6581] ntpd: not installed
      2024-10-22 01:11:06 [6581] ntpdate: not installed
      2024-10-22 01:11:06 [6581] node ntp -> 0.pool.ntp.org (UDP/123)
      2024-10-22 01:11:06 [6581]   NTP 0.pool.ntp.org: server unix=1794834702 local unix=1729534266 offset=65300436s
      2026-11-16 20:11:42 [6581] setSystemTime reply: {"returnValue":true}
      2026-11-16 20:11:42 [6581] SUCCESS via NTP 0.pool.ntp.org: 2026-11-16 20:11:42
      2026-11-16 20:11:42 [6581] toast rc=0 msg=[Time set OK via NTP 0.pool.ntp.org (2026-11-16 20:11:42)] reply={    "returnValue": true,    "toastId": "ntp-sync-1794834702581"}
      ```
