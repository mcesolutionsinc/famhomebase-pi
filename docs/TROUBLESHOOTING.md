# Troubleshooting

## Install and start-up

**Docker: `dpkg returned an error code (1)`, no `docker` group, or no `docker.service`**: see the note under "Install Docker" in the
[install guide](INSTALL.md): Debian's `docker-buildx`/`docker-compose` packages clash with Docker's own, and the command-line client alone
doesn't include the engine.

**The installer says it could not pull the image** ("denied"): the image package must be public, or Docker must be logged in. If the Docker
daemon can't be reached, add yourself to the docker group (`sudo usermod -aG docker $USER`), log out and back in, and run the installer again.

**The display doesn't start**: `journalctl -u famhomebase --no-pager -n 50` and `docker logs famhomebase-display`. A refused setting (a bad
`FAMHOMEBASE_API_URL`, port or environment) is one JSON line saying which.

**The port is already in use** (it is port 80 for a new install): pick another with `--port 8080` (run the installer again) or set
`FAMHOMEBASE_PORT=8080` in `/etc/famhomebase/famhomebase.env` and run `sudo systemctl restart famhomebase`. The kiosk follows the setting.

**I can't open the display from my laptop**: on purpose. It listens on `127.0.0.1` only. To look at it from another computer while testing, either
use an SSH tunnel (`ssh -L 8080:localhost:80 <user>@<the Pi's address>`, then open <http://localhost:8080/>) or set `FAMHOMEBASE_BIND=0.0.0.0`
in the settings file and restart `famhomebase` (and put it back afterwards).

## The Pi's screen

**Nothing appears on the screen after boot**: `systemctl --user status famhomebase-kiosk`. It waits up to 5 minutes for the desktop to come up
and then tries again. If it isn't installed, run the installer with `--kiosk`. Check desktop autologin is on
(`sudo raspi-config nonint do_boot_behaviour B4`).

**The kiosk restarts every few seconds and the log says `Zygote process exited prematurely`**: Chromium downloaded a DRM component (Widevine)
into its saved profile and crashes on it at the next start. Releases from 0.2.0 stop it and clean it up by themselves. On an older install:
`rm -rf /var/lib/famhomebase/kiosk-profile/WidevineCdm` and `systemctl --user restart famhomebase-kiosk`. The pairing is kept.

**The screen is the wrong way up**: it is a setting of the device on the website (Devices, the device's Settings, Screen rotation). The QR
screen of a device that has never been paired can't know its rotation, and shows unturned until it is paired.

**The display shows the full menu**: the address needs `?kiosk=1` (the kiosk service adds it).

**A widget says "Weather is not available right now"**: the weather service did not answer (a Pi that has only just booted may not have its
network yet). It asks again within a minute.

## Updates

**Did it update?** `famhomebase version` is the release you're on; `famhomebase logs` (or `journalctl -u famhomebase-update --no-pager -n 20`) says what the
updater last did (JSON lines). It checks every 6 hours (`CHECK_INTERVAL_HOURS`) and waits 10 minutes after boot.

**A release failed to start and was rolled back**: the log says so, and that version is skipped for a day. Your pairing and layout were never
touched. Tell us in an issue with the log lines.

**"could not look up the latest release"**: GitHub could not be reached (or answered too often); it tries again at the next check.

**Turn updates off**: `AUTO_UPDATE=false` in `/etc/famhomebase/famhomebase.env`.

## Pairing

**The code on the screen is refused**: codes last 10 minutes and the screen shows a new one by itself. Type the one on the screen now.

**The pairing page says "You have no displays yet"**: make a display on the website first (Displays, New display); the code is kept.

## Still stuck?

[Open an issue](../../../issues/new/choose) with `journalctl -u famhomebase --no-pager -n 100` and `docker ps`.
