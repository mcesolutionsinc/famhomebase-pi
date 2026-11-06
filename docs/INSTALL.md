# Install guide

From a fresh Pi to a working dashboard on the wall. You can do all of it over SSH — no keyboard or mouse on the Pi
is needed. This covers installing and running it; how to use the dashboard is a separate guide.

## 1. What you need

- A Raspberry Pi 4 or 5 running a **64-bit** Raspberry Pi OS with the **desktop** (the display runs in a browser), or
  any 64-bit Linux machine with a desktop
- A screen, and SSH access to the Pi from a laptop
- Docker with the Compose plugin (next section)

## 2. Install Docker

On Raspberry Pi OS, the simplest route is Docker's own install script. It installs the engine and the Compose
plugin, and sets Docker to start on boot:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER      # then log out and back in
```

Check it worked:

```bash
systemctl status docker            # active (running)
docker compose version             # must work — the next steps use it
docker run --rm hello-world
```

> **If the install stops with `dpkg returned an error code (1)`, or there is no `docker` group:** Debian's own
> `docker-buildx` and `docker-compose` packages can clash with Docker's plugins. Remove them, finish the install,
> and add Docker's plugins:
>
> ```bash
> sudo apt-get remove -y docker-buildx docker-compose
> sudo dpkg --configure -a
> sudo apt-get install -y docker-buildx-plugin docker-compose-plugin
> ```
>
> Having `/usr/bin/docker` is not enough: a command-line client without the engine gives you no `docker.service`.

## 3. Install FamHomeBase

One command downloads the latest release, creates the encryption key, and starts everything:

```bash
curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sh
```

It installs into `~/famhomebase-pi`. Options go after `sh -s --`, for example `--port 8080` serves it on that port instead
(the default is port 80, so the address is plain `http://<address>/`; the port must be free on this machine, and `--port 8080` is a common alternative), `... | sh -s -- --kiosk` also sets the Pi up to
show the dashboard full-screen at boot (section 5), `--dir /some/folder` installs elsewhere, and
`--version 0.1.5` picks a release. Running it again on an existing install updates it and leaves your settings, accounts
and key alone.

> **Back up `~/famhomebase-pi/secrets/dashboard.key`, separately from `./data`.** It encrypts your connected-account
> tokens. If you lose it you keep your layout and settings but have to reconnect your calendars.

Check it's healthy (about 30 seconds after the first start):

```bash
cd ~/famhomebase-pi
docker compose ps          # app, configstore and updater should be running; the first two "healthy"
docker compose logs -f
```

The first start downloads two images: the app and a small background service that stores your settings.

<details>
<summary>Installing by hand instead (a git clone)</summary>

```bash
git clone https://github.com/mcesolutionsinc/famhomebase-pi.git
cd famhomebase-pi
./scripts/generate-key.sh
docker compose up -d
```

A clone follows the newest images (`latest`) but is a development checkout: it does **not** update itself, and you
update it with `git pull && docker compose pull && docker compose up -d`.

</details>

## 4. Set it up from your laptop

> The addresses in this guide use port 80, the default, so they have no port number. If you chose another with `--port`, or set `FAMHOMEBASE_PORT` in
> `~/famhomebase-pi/.env` (then `docker compose up -d`), add it: `http://<pi-address>:8080/`. The kiosk scripts follow the setting.

Open `http://<pi-address>/` on a laptop on the same network (find the address with `hostname -I` on the Pi).
Without `?kiosk=1` you get the full interface: customize the layout, connect calendars, change settings. Changes are
saved on the Pi, so the display picks them up.

**The first time, it asks you to set an admin PIN** before showing anything — without one, anyone on your network
could change your dashboard. After that, viewing the dashboard needs no PIN, but Customize, Accounts and Settings ask
for it. The Pi's own screen (`?kiosk=1`) never asks. The connection is plain HTTP on your home network, so the PIN
isn't encrypted in transit — don't reuse one you use elsewhere.

### Subscribing

The dashboard needs a subscription. Subscribe once, from your laptop. The whole Pi is a single customer, so the
Pi's own screen — which sits on the subscription page until then — unlocks by itself within about 15 seconds.

### Connecting Google Calendar

Google sign-in needs a *secure* page (HTTPS, or `localhost`), and Google only allows sign-in to return to `localhost`.
Opened from `http://<pi-address>/`, the Connect buttons stay greyed out and the page explains why. The way around
it needs only SSH: forward the Pi's port to your laptop, then browse to your laptop's own `localhost`.

On your **laptop**, in a terminal:

```bash
ssh -L 8080:localhost:80 <user>@<pi-address>
```

Leave that open, then browse to **`http://localhost:8080/`** on the laptop → Accounts → Connect Google, and leave
every permission box ticked. If your laptop already uses port 8080, use another local port, e.g.
`ssh -L 9090:localhost:80 …` and `http://localhost:9090/`. (If your Pi is on port 8080, forward to that: `-L 8080:localhost:8080`.) You only need the tunnel while connecting an account.

## 5. Show it on the Pi's screen

The display is the same page with `?kiosk=1`, which hides the menu and the mouse pointer. On Raspberry Pi OS with the
desktop (labwc), one command sets it up: a small **systemd user service** that opens the dashboard full-screen, waits for it
to be up first, and restarts the browser if it ever crashes.

```bash
curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sh -s -- --kiosk
```

That also turns on desktop autologin (so the Pi needs no keyboard at boot) and starts the service now. Reboot to see it come
up on its own.

The service just runs `~/famhomebase-pi/scripts/kiosk.sh`, which reads its settings from `.env` every time it starts — so
updates, port changes and rotation never need anything in your home folder edited. An older install that opened the
dashboard from `~/.config/labwc/autostart` is moved over to the service automatically the next time you run the installer
(the old file is saved as `autostart.bak`, and your other lines in it stay).

Restart the display after you change something, from SSH:

```bash
systemctl --user restart famhomebase-kiosk        # restart the display
systemctl --user status famhomebase-kiosk         # is it running? and what did it last say?
# (the status output ends with the service's recent log lines)
```

### Rotate the screen

For a portrait display, set the rotation (90, 180 or 270; try the other if it comes out upside down):

```bash
curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sh -s -- --rotate 90
```

or edit `~/famhomebase-pi/.env` yourself (`FAMHOMEBASE_ROTATE=90`, and `FAMHOMEBASE_OUTPUT=HDMI-A-1` if you have more than one
display) and run `systemctl --user restart famhomebase-kiosk`. The installer adds `wlr-randr` for you with `--kiosk` (or `sudo apt install wlr-randr`). `--rotate normal` puts it back. Then
set the screen's orientation in the dashboard under Settings. A touchscreen may need its own rotation.

<details>
<summary>Doing it by hand instead</summary>

Create `~/.config/systemd/user/famhomebase-kiosk.service`:

```ini
[Unit]
Description=FamHomeBase kiosk display

[Service]
ExecStart=/home/<you>/famhomebase-pi/scripts/kiosk.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

then `systemctl --user daemon-reload && systemctl --user enable --now famhomebase-kiosk` and
`sudo raspi-config nonint do_boot_behaviour B4` (desktop autologin). This is for the labwc (Wayland) desktop; an older
X11-based install isn't covered.

</details>

## 6. Start on boot

The containers use `restart: unless-stopped`, so they return after a reboot as long as Docker does. The install
script above already enables Docker on boot; if you installed it another way, run `sudo systemctl enable docker`.

## Updating

**Automatic, by default.** The `updater` service checks GitHub for a new release every 6 hours. When there is one it
downloads it, checks its checksum, pulls the new images, restarts the dashboard, and waits for it to be healthy. If the new
version doesn't come up, it puts the previous one back and won't retry that version for a day. Your `./data`, `./secrets`
and `.env` are never touched. The dashboard blinks for about a minute while it restarts, and the first time you open the
admin screens afterwards you'll be asked for your PIN again. Reload the Pi's browser to pick up the new page
(`systemctl --user restart famhomebase-kiosk`, or `sudo reboot`) — newer versions of the display reload themselves.

See what it's doing:

```bash
cd ~/famhomebase-pi
docker compose logs updater --tail 20
cat VERSION                 # the release you're on
```

**Turn it off.** Set `AUTO_UPDATE=false` in `~/famhomebase-pi/.env` and run `docker compose up -d`. The updater then only logs that
a release is available (and writes its number to `.update-available`).

**Update by hand** at any time by running the installer again (section 3).

The updater needs access to Docker's control socket, which is effectively root on this machine; that is how any
compose-based updater works. If you'd rather not have that, turn it off and update by hand.

## Backups

Back up **both** `./data` and `./secrets/dashboard.key`, and keep the key somewhere other than the same disk.

## Uninstalling

```bash
docker compose down        # keeps ./data and ./secrets
docker compose down -v     # also removes the internal socket volume (not your data)
```
