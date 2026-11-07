# Troubleshooting

## Install and start-up

**Docker: `dpkg returned an error code (1)`, no `docker` group, or no `docker.service`** — see the note under
"Install Docker" in the [install guide](INSTALL.md): Debian's `docker-buildx`/`docker-compose` packages clash with
Docker's own, and the command-line client alone doesn't include the engine.

**The containers won't start** — `docker compose logs`. If `configstore` exits immediately, check that
`./secrets/dashboard.key` exists and is exactly 32 bytes (`./scripts/generate-key.sh` makes one).

**A container says "unhealthy" but the page works** — update to the latest `docker-compose.yml` (`git pull`). Older
copies checked `localhost`, which can resolve to an address the web server doesn't listen on.

**The port is already in use** (it's port 80 for a new install) — pick another: set `FAMHOMEBASE_PORT=8080` in `~/famhomebase-pi/.env` and run `docker compose up -d` (or re-run the installer with `--port 8080`). Add the port to the address from then on: `http://<pi-address>:8080/`.

## Updates

**Did it update?** `cat ~/famhomebase-pi/VERSION` is the release you're on; `docker compose logs updater --tail 20` says what the
updater last did. It checks every 6 hours and waits 5 minutes after starting.

**"development checkout ... not updating"** — you installed with `git clone`, which the updater leaves alone. Use the
installer (install guide, section 3) to switch to a release install.

**A release failed to start and was rolled back** — the log says so, and that version is skipped for a day. Your data was
never touched. Tell us in an issue with `docker compose logs --tail 100`.

**The updater container keeps restarting** — check `FAMHOMEBASE_DIR` in `.env` is the full path of this folder. The installer sets it.

**Turn updates off** — `AUTO_UPDATE=false` in `.env`, then `docker compose up -d`.

## The Pi's screen

**Nothing appears on the screen after boot** — check the service: `systemctl --user status famhomebase-kiosk` (it ends with the service's recent log lines). It waits up to 5 minutes for the desktop to come up and then tries again. If it isn't installed, run the installer with `--kiosk`. Check desktop autologin is on (`sudo raspi-config nonint do_boot_behaviour B4`).

**The screen is the wrong way up, or won't rotate** — set `FAMHOMEBASE_ROTATE` in `.env` (90, 180 or 270) and run `systemctl --user restart famhomebase-kiosk`; it needs `sudo apt install wlr-randr`. `systemctl --user status famhomebase-kiosk` says if the rotation failed.

**The display shows the full menu** — the address needs `?kiosk=1`.

**The display shows the subscription page** — subscribe from your laptop; the display unlocks by itself within about
15 seconds. If it doesn't, check the laptop and the Pi are using the same address, and reload the Pi's browser.

**I want the screen dark at night** — turn on **Night mode** in Settings → Display and set **At night, the Pi's screen** to
**Goes black**. The dashboard goes fully black between the times you set (in your timezone) and comes back by itself in the
morning. The TV stays on and connected, so it keeps its rotation and doesn't need turning back on; its backlight still
glows a little, so use the TV's own sleep timer if you want it fully off. **Dims** darkens it without going black.

## Setting it up

**The Connect Google button is greyed out** — you opened the page over plain HTTP. Use the SSH tunnel in the install
guide and browse to `http://localhost:8080/` on your laptop (the tunnel forwards your laptop's 8080 to the Pi).

**An account says "Needs reconnect"** — Google revoked or expired the connection. Press **Reconnect** on that
account's row in Accounts (not Connect Google, which adds a second account without your calendar choices) and sign in
again, leaving every permission box ticked.

**Settings say "Can't reach the Pi"** — the app can't reach its background service. `docker compose ps` should show
both services healthy; try `docker compose restart configstore`.

**The admin screens ask for the PIN again** — normal after an update or restart of the service; enter it.

**I forgot the admin PIN** — on the Pi, in this folder, delete the PIN file and restart the service. Your layout,
settings and connected accounts are not touched; you'll be asked to set a new PIN the next time you open the page:

```bash
rm ./data/pin.json
docker compose restart configstore
```

**My dashboard went back to the default layout, or an account vanished** — the Pi keeps the last 20 versions of your
settings in `./data/history/` (oldest name first, newest last) and keeps an account you remove for 7 days in
`./data/accounts-removed/`. To go back to an earlier layout, stop the service, put that version in place and start it:

```bash
docker compose stop configstore
ls ./data/history                                  # pick the newest one from before it went wrong
cp ./data/history/config-XXXXXXXXXXXXXXX-XXXX.json ./data/config.json
docker compose start configstore
```

To bring back a removed account, copy its file back into `./data/accounts/` with the `.<number>` ending taken off
(`cp ./data/accounts-removed/<name>.<number> ./data/accounts/<name>`), then restart. Reload the page in your browser
afterwards.

## Still stuck?

[Open an issue](../../../issues/new/choose) with the output of `docker compose ps` and
`docker compose logs --tail 100`. Don't paste the contents of `./secrets` or `./data`.
