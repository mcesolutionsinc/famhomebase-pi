# Troubleshooting

## Install and start-up

**The ready-made image: the screen stays black or shows a text prompt for a minute or two on the first start**: that is the one-time set-up. Leave
the Pi plugged in. If there is still no pairing code after five minutes, unplug it, plug it in again, and wait another two minutes. If it
still doesn't show, write the card again.

**The ready-made image: Imager shows no settings screens for it, or does not list FamHomeBase**: Imager needs the FamHomeBase list address
(step 2 of [the easy way](INSTALL.md#the-easy-way-a-ready-made-system-image-raspberry-pi-4-or-5)) and version 2 or newer. Choose the Pi 4 or
Pi 5 first: the image is not offered for older Pis.

**The ready-made image: I can't log in over SSH**: SSH is off unless you turned it on in Imager's Remote access screen. Write the card again
with it on.

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

**An emoji in a calendar entry shows as a blank or an empty box** (a display installed before the image carried the font): Raspberry Pi OS Lite has no
emoji font. On the Pi run `sudo apt install -y fonts-noto-color-emoji && sudo systemctl restart famhomebase-kiosk`. Images built from the release
after 0.5.11 already have it.

**Nothing appears on the screen after boot**: `systemctl status famhomebase-kiosk` and `journalctl -u famhomebase-kiosk -n 50`. If it isn't
installed, run the installer with `--kiosk`. A line `Timeout waiting session to become active` means the kiosk's terminal was not the
one in front (the unit brings terminal 1 forward at start; a desktop left running would hold the screen: `sudo systemctl stop lightdm`).
There is no desktop to fall back to: use SSH, or `sudo systemctl set-default graphical.target` and reboot to get one back.

**The screen goes black for a moment while the kiosk restarts**: it restarts by itself if the browser exits (5 seconds), and when an
update changes its script.

**The kiosk restarts every few seconds and the log says `Zygote process exited prematurely`**: Chromium downloaded a DRM component (Widevine)
into its saved profile and crashes on it at the next start. Releases from 0.2.0 stop it and clean it up by themselves. On an older install:
`rm -rf /var/lib/famhomebase/kiosk-profile/WidevineCdm` and then `sudo systemctl restart famhomebase-kiosk`. The pairing is kept.

**The boot splash is the wrong way up, or the wrong logo shape**: the splash is made for the rotation the display last told the Pi (section 5 of
INSTALL.md). Change the rotation on the website, wait until the dashboard has turned, then give it a minute (the boot image is rebuilt) and
reboot. `cat /var/lib/famhomebase/state/rotation` shows what the Pi knows, and `journalctl -u famhomebase-splash` what the last rebuild did.
`sudo sh /usr/local/lib/famhomebase/splash.sh apply` makes it again by hand.

**The screen is the wrong way up**: it is a setting of the device on the website (Devices, the device's Settings, Screen rotation). The QR
screen of a device that has never been paired can't know its rotation, and shows unturned until it is paired.

**The display shows the full menu**: the address needs `?kiosk=1` (the kiosk service adds it).

**A widget says "Weather is not available right now"**: the weather service did not answer (a Pi that has only just booted may not have its
network yet). It asks again within a minute.

## Updates

**Did it update?** `famhomebase version` is the release you're on; `famhomebase logs` (or `journalctl -u famhomebase-update --no-pager -n 20`) says what the
updater last did (JSON lines). It checks every 6 hours (`CHECK_INTERVAL_HOURS`) and waits 10 minutes after boot.

**The screen says "Updating" for a while on the first start**: that is the first-boot update (see [Updating](INSTALL.md#7-updating)), done once on a new
card before the pairing screen. It gives up after 15 minutes and shows the pairing screen anyway. `cat /var/lib/famhomebase/first-boot-update-done`
says how it ended (`updated`, `up-to-date`, `offline`, `disabled`, `failed` or `timeout`); `journalctl -u famhomebase-first-update --no-pager` has the
details. To run it again on a card: `sudo rm /var/lib/famhomebase/first-boot-update-done` and restart.

**A release failed to start and was rolled back**: the log says so, and that version is skipped for a day. Your pairing and layout were never
touched. Tell us in an issue with the log lines.

**"could not look up the latest release"**: GitHub could not be reached (or answered too often); it tries again at the next check.

**Turn updates off**: `AUTO_UPDATE=false` in `/etc/famhomebase/famhomebase.env`.

## Pairing

**The code on the screen is refused**: codes last 10 minutes and the screen shows a new one by itself. Type the one on the screen now.

**The pairing page says "You have no displays yet"**: make a display on the website first (Displays, New display); the code is kept.

## Still stuck?

[Open an issue](../../../issues/new/choose) with `journalctl -u famhomebase --no-pager -n 100` and `docker ps`.
