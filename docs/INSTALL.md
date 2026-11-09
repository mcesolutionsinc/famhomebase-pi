# Install guide

From a fresh Pi to a working display on the wall. You can do all of it over SSH: no keyboard or mouse on the Pi is needed. This covers
installing and running the display; the website's guide covers building what it shows.

## 1. What you need

- A Raspberry Pi 3, 4 or 5 (64-bit) running **64-bit** Raspberry Pi OS with the **desktop** (the display runs in a browser), or any 64-bit
  Linux machine with systemd and a desktop. A Pi 4 is a comfortable choice.
- A screen, and SSH access to the Pi from a laptop
- Docker (next section). Docker Compose is **not** needed: the display is one container started by systemd.
- A FamHomeBase account on the website, with a display made (the Displays page)

## 2. Install Docker

On Raspberry Pi OS, the simplest route is Docker's own install script. It installs the engine and sets Docker to start on
boot:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER      # then log out and back in
```

Check it worked:

```bash
systemctl status docker            # active (running)
docker run --rm hello-world
```

> **If the install stops with `dpkg returned an error code (1)`, or there is no `docker` group:** Debian's own
> `docker-buildx` and `docker-compose` packages can clash with Docker's. Remove them and finish the install:
>
> ```bash
> sudo apt-get remove -y docker-buildx docker-compose
> sudo dpkg --configure -a
> ```
>
> Having `/usr/bin/docker` is not enough: a command-line client without the engine gives you no `docker.service`.

## 3. Install FamHomeBase

One command downloads the newest release, pulls the display image and sets everything up. On the Pi:

```bash
curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sh -s -- --kiosk
```

It asks for your sudo password once (it writes systemd units). The options:

| Option       | Meaning                                                                                                          | Default                         |
| ------------ | ---------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| `--env`      | `prod` or `staging` (staging shows a STAGING tag and uses the staging site)                                      | `prod`                          |
| `--api-url`  | where the cloud is, `https://host` with no path; a phone scanning the QR code opens the same address            | the site that goes with `--env` |
| `--port`     | the port the display listens on                                                                                  | `80`                            |
| `--kiosk`    | show the display full-screen at boot (Raspberry Pi OS desktop): turns on desktop autologin, runs the kiosk service | off                             |
| `--dir`      | where to install (a plain path, no spaces)                                                                       | `~/famhomebase`                 |
| `--version`  | install that release instead of the newest                                                                       | the newest                      |
| `--no-start` | set up, but start nothing                                                                                        |                                 |

Running it again keeps your `.env` and changes only what you pass, so `--env prod` later moves a staging display to production. A display
paired to the other environment is refused by the cloud and shows a new code by itself.

## 4. Pair it

The screen shows the FamHomeBase mark, a QR code and a code such as `K7QM-4T9X`. On your phone scan the QR code (or open
`<the site>/app/pair` and type the code), sign in, name the device, pick a display, and pick the picture that matches how the text looks on
the wall screen (so a screen mounted on its side turns itself the right way). The screen shows your layout within a few seconds, and follows
every edit you make on the website.

Things you change later are on the website: the display's layout and look, and the device's time zone, time format, night dimming and
rotation (Devices, then the device's Settings).

## 5. What runs where

- **The container** (`ghcr.io/mcesolutionsinc/famhomebase-pi:<version>`): nginx serving the page and passing `/api/` on to the cloud. Started by
  the `famhomebase` systemd unit through `scripts/run.sh`, which reads `.env` and `VERSION`. Logs: `journalctl -u famhomebase`.
- **The kiosk** (`--kiosk`): the user service `famhomebase-kiosk` runs `scripts/kiosk.sh`: Chromium full-screen on the page, with a saved
  profile (`FAMHOMEBASE_PROFILE`) that keeps the display's pairing and its last layout across restarts and power cuts. Check it with
  `systemctl --user status famhomebase-kiosk`.
- **The updater**: the `famhomebase-update` timer runs `scripts/update.sh` every few hours (section 7).

A bad `FAMHOMEBASE_API_URL` stops the container at start with one JSON line saying why; the cloud's address is looked up again every 30
seconds, and a start with no DNS still comes up (`docker logs famhomebase-display`).

## 6. Settings in `.env`

| Setting                | Meaning                                                                                 | Default                                |
| ---------------------- | --------------------------------------------------------------------------------------- | -------------------------------------- |
| `FAMHOMEBASE_ENV`      | `prod` or `staging`                                                                     | `prod`                                 |
| `FAMHOMEBASE_API_URL`  | where the cloud is                                                                      | `https://famhomebase.mc-esolutions.ca` |
| `FAMHOMEBASE_PORT`     | the port the display listens on                                                         | `80`                                   |
| `AUTO_UPDATE`          | `false` = only log that a release is available                                          | `true`                                 |
| `CHECK_INTERVAL_HOURS` | how often the timer looks for a release (1 to 168); applies after the next host setup  | `6`                                    |
| `FAMHOMEBASE_PROFILE`  | where the kiosk keeps the browser's saved data                                          | `~/.local/share/famhomebase-kiosk`     |
| `FAMHOMEBASE_IMAGE`    | the image, without a tag (for one you built yourself)                                   | `ghcr.io/mcesolutionsinc/famhomebase-pi` |

After changing `.env` run `sudo systemctl restart famhomebase` (and `systemctl --user restart famhomebase-kiosk` for the profile).

**Screen rotation is not a setting here.** It is a setting of the device on the website, so it can be changed without touching the Pi.

## 7. Updating

A release is the container image **and** a payload of host files (the scripts and the text of the units) with the same version number. Every few
hours the timer runs `scripts/update.sh`, which:

1. finds the newest `vX.Y.Z` release;
2. downloads its payload and checks the sha256; pulls the image (if either fails, nothing has changed);
3. saves the current files, swaps the new ones in, applies them (`host-setup.sh --update`: the units, a restart of the display and, if its files
   changed, of the kiosk), and waits for the display to be healthy on the new version;
4. if anything fails, puts the old files back and restarts the old version, then leaves that release alone for a day.

Your `.env` is never touched. See what it did with `journalctl -u famhomebase-update` (JSON lines). Run it now with
`sudo sh ~/famhomebase/scripts/update.sh`.

## 8. Try it on a computer, without systemd

```bash
docker run -d --name famhomebase-display --restart unless-stopped -p 8080:8080 \
  -e FAMHOMEBASE_API_URL=https://famhomebase.mc-esolutions.ca -e FAMHOMEBASE_ENV=prod \
  ghcr.io/mcesolutionsinc/famhomebase-pi:0.2.0
```

Open <http://localhost:8080/>. (An image you built yourself from the app repo works the same: `docker build -f mobile/Dockerfile -t famhomebase-pi:local mobile`.)

## 9. What it keeps, and what to expect

- The display's secret and its last layout live in the **browser's** saved data, not in the container. A new browser profile, or removing the
  device on the website's Devices page, shows a new code.
- With no internet it keeps showing the last layout it had; a first start with no internet shows "Connecting".
- It picks up an edit from the website within seconds (live push), and checks at least once a minute.
- Pairing codes change every 10 minutes. A display nobody sets up stops asking after 24 hours and says "Restart this device to set it up."

## 10. Uninstalling

```bash
sudo systemctl disable --now famhomebase famhomebase-update.timer
sudo rm /etc/systemd/system/famhomebase.service /etc/systemd/system/famhomebase-update.* && sudo systemctl daemon-reload
systemctl --user disable --now famhomebase-kiosk   # if it was a kiosk
rm -rf ~/famhomebase
```
