# Install guide

From a fresh Pi to a working display on the wall. You can do all of it over SSH: no keyboard or mouse on the Pi is needed. This covers
installing and running the display; the website's guide covers building what it shows.

## 1. What you need

- A Raspberry Pi 3, 4 or 5 (64-bit) running **64-bit** Raspberry Pi OS, **Lite is enough** (no desktop is needed: the kiosk runs under `cage`,
  and `--kiosk` installs it and the browser), or any 64-bit Linux machine with systemd. A Pi 4 is a comfortable choice.
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
curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sudo sh -s -- --kiosk
```

It needs root (that is the `sudo`): it installs into `/usr/local` and `/etc`, the standard places for a service, and writes the systemd units. Run it from the login of the user whose desktop shows the display, or add `--user NAME`. The options:

| Option       | Meaning                                                                                                          | Default                         |
| ------------ | ---------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| `--env`      | `prod` or `staging` (staging shows a STAGING tag and uses the staging site)                                      | `prod`                          |
| `--api-url`  | where the cloud is, `https://host` with no path; a phone scanning the QR code opens the same address            | the site that goes with `--env` |
| `--port`     | the port on this machine (the display listens on `127.0.0.1` only: nothing else on the network can reach it)    | `80`                            |
| `--kiosk`    | show the display full-screen at boot, with no desktop: installs `cage` and the browser if missing and runs the kiosk as a system service of its own user | off                             |
| `--user`     | the user whose old desktop kiosk service (installs before 0.4.0) is removed                                      | the user who ran `sudo`         |
| `--version`  | install that release instead of the newest                                                                       | the newest                      |
| `--no-start` | set up, but start nothing                                                                                        |                                 |

Running it again keeps your settings and changes only what you pass, so `--env prod` later moves a staging display to production. A display
paired to the other environment is refused by the cloud and shows a new code by itself.

## 4. Pair it

The screen shows the FamHomeBase mark, a QR code and a code such as `K7QM-4T9X`. On your phone scan the QR code (or open
`<the site>/app/pair` and type the code), sign in, name the device, pick a display, and pick the picture that matches how the text looks on
the wall screen (so a screen mounted on its side turns itself the right way). The screen shows your layout within a few seconds, and follows
every edit you make on the website.

Things you change later are on the website: the display's layout and look, and the device's time zone, time format, night dimming and
rotation (Devices, then the device's Settings).

## 5. What is installed, and where

| What | Where |
| --- | --- |
| The scripts and `VERSION` | `/usr/local/lib/famhomebase/` |
| The `famhomebase` command | `/usr/local/bin/famhomebase` (`status`, `logs`, `update`, `version`, `settings`) |
| Your settings | `/etc/famhomebase/famhomebase.env` (an update never changes it; the release's own example is `famhomebase.env.example` beside it) |
| State: the saved copy for a way back, the kiosk's browser profile, the screen's rotation for the boot splash | `/var/lib/famhomebase/` |
| This guide, the README and the licence | `/usr/local/share/doc/famhomebase/` |
| The systemd units | `/etc/systemd/system/`: `famhomebase.service`, `famhomebase-update.service`, `famhomebase-update.timer`, and with `--kiosk` `famhomebase-kiosk.service` |

- **The container** (`ghcr.io/mcesolutionsinc/famhomebase-pi:<version>`): nginx serving the page and passing `/api/` on to the cloud. Started by
  the `famhomebase` unit through `run.sh`, published on `127.0.0.1:80`. Logs: `famhomebase logs` (or `journalctl -u famhomebase`).
- **The kiosk** (`--kiosk`): the system service `famhomebase-kiosk` runs `cage` (a compositor that shows one program, full screen, and
  nothing else) which runs `kiosk.sh`: Chromium on `http://localhost/`. It runs as its own user, `famhomebase-kiosk` (no password, no
  shell), on the first virtual terminal. There is **no desktop and no login manager**: the Pi boots to the display. Its saved profile in
  `/var/lib/famhomebase/kiosk-profile` keeps the display's pairing and its last layout across restarts and power cuts. Check it with
  `systemctl status famhomebase-kiosk` and `journalctl -u famhomebase-kiosk`.
- **The boot splash** (`--kiosk`): from the first moment the kernel runs, the screen shows the FamHomeBase logo and three moving dots (a wide
  logo on a landscape screen, a tall one on a portrait screen, turned for how the screen is mounted), with no boot text and no cursor. It is a
  Plymouth theme made by `splash.sh`. The first couple of seconds, while the Pi's own firmware starts, are plain black. When the browser
  opens, the app's own start screen shows the same logo and dots, so nothing seems to change. Plymouth cannot ask the cloud how the screen is
  mounted, so the display's page tells its web server (`PUT /local/rotation`, kept in `/var/lib/famhomebase/state/rotation`) as soon as it knows;
  the unit `famhomebase-splash.path` then makes the theme again and rebuilds the boot image (about half a minute, once for each change). A
  display that has never been paired, or whose rotation you have just changed, shows the splash turned for the old rotation until the next
  boot after that.
- **The updater**: the `famhomebase-update` timer runs `update.sh` every few hours (section 7).

Everything in `/usr/local` is root's, so nothing that runs as root lives in a user's folder.

A bad `FAMHOMEBASE_API_URL` stops the container at start with one JSON line saying why; the cloud's address is looked up again every 30
seconds, and a start with no DNS still comes up (`docker logs famhomebase-display`).

## 6. Settings

The file is `/etc/famhomebase/famhomebase.env` (`famhomebase settings` prints the path).

| Setting                | Meaning                                                                                 | Default                                |
| ---------------------- | --------------------------------------------------------------------------------------- | -------------------------------------- |
| `FAMHOMEBASE_ENV`      | `prod` or `staging`                                                                     | `prod`                                 |
| `FAMHOMEBASE_API_URL`  | where the cloud is                                                                      | `https://famhomebase.mc-esolutions.ca` |
| `FAMHOMEBASE_PORT`     | the port on this machine                                                                | `80`                                   |
| `FAMHOMEBASE_BIND`     | the address it listens on. `0.0.0.0` only to look at the display from another computer while testing | `127.0.0.1`               |
| `AUTO_UPDATE`          | `false` = only log that a release is available                                          | `true`                                 |
| `CHECK_INTERVAL_HOURS` | how often the timer looks for a release (1 to 168); applies after the next host setup  | `6`                                    |
| `FAMHOMEBASE_PROFILE`  | where the kiosk keeps the browser's saved data                                          | `/var/lib/famhomebase/kiosk-profile`   |
| `FAMHOMEBASE_IMAGE`    | the image, without a tag (for one you built yourself)                                   | `ghcr.io/mcesolutionsinc/famhomebase-pi` |

After changing it run `sudo systemctl restart famhomebase` (and `sudo systemctl restart famhomebase-kiosk` for the profile).

**Screen rotation is not a setting here.** It is a setting of the device on the website, so it can be changed without touching the Pi.

## 7. Updating

A release is the container image **and** a payload of host files (the scripts and the text of the units) with the same version number. Every few
hours the timer runs `update.sh`, which:

1. finds the newest `vX.Y.Z` release;
2. downloads its payload and checks the sha256; pulls the image (if either fails, nothing has changed);
3. saves the current files (in `/var/lib/famhomebase/rollback`), swaps the new ones in, applies them (`host-setup.sh --update`: the units, a
   restart of the display and, if its files changed, of the kiosk), and waits for the display to be healthy on the new version;
4. if anything fails, puts the old files back and restarts the old version, then leaves that release alone for a day.

Your settings file is never touched. See what it did with `famhomebase logs` (JSON lines). Run it now with `famhomebase update`.

## 8. Try it on a computer, without systemd

```bash
docker run --rm --name famhomebase-try -p 8080:8080 \
  -e FAMHOMEBASE_API_URL=https://famhomebase.mc-esolutions.ca -e FAMHOMEBASE_ENV=prod \
  ghcr.io/mcesolutionsinc/famhomebase-pi:<a version from the Releases page>
```

Open <http://localhost:8080/>; stop it with Ctrl-C. (An image you built yourself from the app repo works the same:
`docker build -f mobile/Dockerfile -t famhomebase-pi:local mobile`.) It has its own name, so it does not clash with an installed display.

## 9. What it keeps, and what to expect

- The display's secret and its last layout live in the **browser's** saved data, not in the container. A new browser profile, or removing the
  device on the website's Devices page, shows a new code.
- With no internet it keeps showing the last layout it had; a first start with no internet shows "Connecting".
- It picks up an edit from the website within seconds (live push), and checks at least once a minute.
- Pairing codes change every 10 minutes. A display nobody sets up stops asking after 24 hours and says "Restart this device to set it up."

## 10. Moving from an earlier install

Before 0.3.0 the display lived in a folder in the user's home (`~/famhomebase`, with its settings in `~/famhomebase/.env`) and the kiosk
browser's saved data in `~/.local/share/famhomebase-kiosk`, on port 8080 or 80 and open to the whole network. Run this release's installer as
above. It takes over the settings that still mean something (environment, address, auto-update), replaces the units, and starts the display
on `127.0.0.1:80`. Then:

- **Pair the display again.** The browser keeps the pairing for one address, and the address is now `http://localhost/`. Remove the old device
  on the website's Devices page.
- Once it works, delete the old folders: `rm -rf ~/famhomebase ~/.local/share/famhomebase-kiosk`. (From before 0.2.0, also `~/famhomebase-cloud`.)

An install of 0.2.x does not update itself to 0.3.0 (the layout changed): it stays on 0.2.x until you run the installer.

**From 0.4.0 the kiosk has no desktop.** An install that ran the kiosk in the desktop (0.3.x and before) moves by itself when it updates: the
old user service is removed, `cage`, the browser and the `famhomebase-kiosk` user are set up, and the Pi boots to the text target instead
of the desktop. A Pi used for other things as well as the display should not use `--kiosk`: it keeps its desktop and the display runs only
as the container (open <http://localhost/> yourself).

## 11. Uninstalling

```bash
sudo systemctl disable --now famhomebase famhomebase-update.timer
sudo rm /etc/systemd/system/famhomebase.service /etc/systemd/system/famhomebase-update.* && sudo systemctl daemon-reload
sudo systemctl disable --now famhomebase-kiosk   # if it was a kiosk
sudo rm -f /etc/systemd/system/famhomebase-kiosk.service && sudo systemctl daemon-reload
sudo systemctl set-default graphical.target       # if you want the desktop back (a Pi with a desktop installed)
sudo userdel famhomebase-kiosk
sudo rm -rf /usr/local/lib/famhomebase /usr/local/share/doc/famhomebase /usr/local/bin/famhomebase /etc/famhomebase /var/lib/famhomebase
```
