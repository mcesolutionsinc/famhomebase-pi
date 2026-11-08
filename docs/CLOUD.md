# FamHomeBase cloud display (preview)

The new line of FamHomeBase keeps your layouts in the cloud. A display is one container that shows a QR code, waits for you to
pair it from your phone, and then draws the layout you made on the website. It runs beside, not instead of, a current Pi: the
images, the install folder and the releases (`cloud-vX.Y.Z`) are all separate from the current line (`vX.Y.Z`).

> **Status:** preview. The container, the installer and the update timer are tested with stand-ins; they have been run on a real Pi
> only at the swap-over checks (`docs/plans/famhomebase-pi-plan.md` in the platform repo, phase C).

## Install on a Pi (or any 64-bit Linux with Docker and systemd)

Docker must already be installed (`docs/INSTALL.md`, "Install Docker"). Compose is **not** needed: the display is one container started
by systemd. Then, on the Pi:

```sh
curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/download/cloud-v0.1.0/cloud-install.sh | sh -s -- --env staging --kiosk
```

(`cloud-v0.1.0` is the release to install; the newest one is on the repo's Releases page.)

| Option          | Meaning                                                                                                 | Default                       |
| --------------- | ------------------------------------------------------------------------------------------------------- | ----------------------------- |
| `--env`         | `prod` or `staging` (staging shows a STAGING banner and uses the staging site)                          | `prod`                        |
| `--api-url`     | where the cloud is, `https://host` with no path; a phone scanning the QR code opens the same address   | the site that goes with `--env` |
| `--port`        | the port you browse to                                                                                  | `80`                          |
| `--kiosk`       | show the display full-screen at boot (Raspberry Pi OS desktop): desktop autologin and a systemd user service | off                      |
| `--dir`         | where to install                                                                                        | `~/famhomebase-cloud`         |
| `--version`     | install that release instead of the newest                                                              | the newest                    |
| `--no-start`    | set up, but start nothing                                                                               |                               |

Open the Pi's own screen at `http://localhost/?kiosk=1` (with `--kiosk` it opens by itself). You will see a QR code and a code like
`K7QM-4T9X`. On your phone scan the QR (or open `<site address>/app/pair` and type the code), sign in, name the device and pick a display.
The screen changes to your layout within a few seconds of pairing.

Running the installer again keeps your `.env` and changes only what you pass, so `--env prod` later moves a staging display to production.
A display paired to the other environment is refused by the cloud and shows a new code by itself.

**Beside a current Pi** (to try it without touching a working one): use `--port 8080` and leave out `--kiosk`. The current line's kiosk
keeps showing on the screen; open `http://<the Pi's address>:8080/` from a laptop to see the new display. Without `--kiosk` the installer
leaves another install's kiosk service alone.

## What runs where

- **The container** (`ghcr.io/mcesolutionsinc/famhomebase-pi-cloud:<version>`): nginx serving the page and passing `/api/` on to the cloud.
  Started by the `famhomebase-cloud` systemd unit through `scripts/cloud-run.sh`, which reads `.env` and `VERSION`. Logs: `journalctl -u famhomebase-cloud`.
- **The kiosk** (`--kiosk`): the user service `famhomebase-kiosk` runs `scripts/kiosk.sh`: Chromium full-screen on the page, with a saved
  profile (`FAMHOMEBASE_PROFILE`) that keeps the display's pairing and its last layout across restarts and power cuts.
- **The updater**: the `famhomebase-cloud-update` timer runs `scripts/cloud-update.sh` every few hours (see below).

A bad `FAMHOMEBASE_API_URL` stops the container at start with one JSON line saying why; the cloud's address is looked up again every 30
seconds, and a start with no DNS still comes up (`docker logs famhomebase-display`).

## Settings in `.env`

| Setting                | Meaning                                                                                 | Default                                |
| ---------------------- | --------------------------------------------------------------------------------------- | -------------------------------------- |
| `FAMHOMEBASE_ENV`      | `prod` or `staging`                                                                     | `prod`                                 |
| `FAMHOMEBASE_API_URL`  | where the cloud is                                                                      | `https://famhomebase.mc-esolutions.ca` |
| `FAMHOMEBASE_PORT`     | the port you browse to                                                                  | `80`                                   |
| `AUTO_UPDATE`          | `false` = only log that a release is available                                          | `true`                                 |
| `CHECK_INTERVAL_HOURS` | how often the timer looks for a release (1 to 168); applies after the next host setup   | `6`                                    |
| `FAMHOMEBASE_PROFILE`  | where the kiosk keeps the browser's saved data                                          | `~/.local/share/famhomebase-kiosk`     |

After changing `.env` run `sudo systemctl restart famhomebase-cloud` (and `systemctl --user restart famhomebase-kiosk` for the profile).

**Screen rotation is not a setting here.** It is a setting of the device on the website (Devices, then the device's Settings), so it can
be changed without touching the Pi.

## Updates

A release is the container image **and** a payload of host files (the scripts and the text of the units) with the same version number. Every
few hours the timer runs `scripts/cloud-update.sh`, which:

1. finds the newest `cloud-vX.Y.Z` release (the current line's `v*` releases are ignored);
2. downloads its payload and checks the sha256; pulls the image (if either fails, nothing has changed);
3. saves the current files, swaps the new ones in, applies them (`cloud-host-setup.sh --update`: the units, a restart of the display and, if
   its files changed, of the kiosk), and waits for the display to be healthy;
4. if anything fails, puts the old files back and restarts the old version, then leaves that release alone for a day.

Your `.env` is never touched. See what it did with `journalctl -u famhomebase-cloud-update` (JSON lines). Run it now with `sudo sh ~/famhomebase-cloud/scripts/cloud-update.sh`.

## Try it on a computer, without systemd

```sh
docker run -d --name famhomebase-display --restart unless-stopped -p 8080:8080 \
  -e FAMHOMEBASE_API_URL=https://staging.famhomebase.mc-esolutions.ca -e FAMHOMEBASE_ENV=staging \
  ghcr.io/mcesolutionsinc/famhomebase-pi-cloud:0.1.0
```

Open <http://localhost:8080/>. (An image you built yourself from the app repo's `famhomebase-cloud` branch works the same:
`docker build -f mobile/Dockerfile.cloud -t famhomebase-pi-cloud:local mobile`.)

## What it keeps, and what to expect

- The display's secret and its last layout live in the **browser's** saved data, not in the container. A new browser profile, or removing
  the device on the website's Devices page, shows a new code.
- With no internet it keeps showing the last layout it had; a first start with no internet shows "Connecting".
- It picks up an edit from the website within about a minute.
- **Agenda and Day plan** show the calendars you chose on the website, once a Google account is connected there (Account, Google accounts).
- Pairing codes change every 10 minutes. A display nobody sets up stops asking after 24 hours and says "Restart this device to set it up."

## Uninstall

```sh
sudo systemctl disable --now famhomebase-cloud famhomebase-cloud-update.timer
sudo rm /etc/systemd/system/famhomebase-cloud*.service /etc/systemd/system/famhomebase-cloud-update.timer && sudo systemctl daemon-reload
systemctl --user disable --now famhomebase-kiosk   # if it was a kiosk
rm -rf ~/famhomebase-cloud
```
