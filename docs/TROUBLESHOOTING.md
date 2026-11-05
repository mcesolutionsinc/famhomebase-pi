# Troubleshooting

## Install and start-up

**Docker: `dpkg returned an error code (1)`, no `docker` group, or no `docker.service`** — see the note under
"Install Docker" in the [install guide](INSTALL.md): Debian's `docker-buildx`/`docker-compose` packages clash with
Docker's own, and the command-line client alone doesn't include the engine.

**The containers won't start** — `docker compose logs`. If `configstore` exits immediately, check that
`./secrets/dashboard.key` exists and is exactly 32 bytes (`./scripts/generate-key.sh` makes one).

**A container says "unhealthy" but the page works** — update to the latest `docker-compose.yml` (`git pull`). Older
copies checked `localhost`, which can resolve to an address the web server doesn't listen on.

**Port 8080 is already in use** — edit `docker-compose.yml` and change the left-hand number, e.g. `"8081:8080"`.

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

**Nothing appears on the screen after boot** — `which chromium chromium-browser`: the browser is `chromium` on current
Raspberry Pi OS, and a wrong name in the autostart file fails silently. Check desktop autologin is on
(`sudo raspi-config nonint do_boot_behaviour B4`), then follow step 7 of the install guide, including the
by-hand test.

**`Missing X server or $DISPLAY`** when starting Chromium from SSH — add `--ozone-platform=wayland`.

**Chromium asks about a keyring** — add `--password-store=basic` to its command.

**The display shows the full menu** — the address needs `?kiosk=1`.

**The display shows the subscription page** — subscribe from your laptop; the display unlocks by itself within about
15 seconds. If it doesn't, check the laptop and the Pi are using the same address, and reload the Pi's browser.

## Setting it up

**The Connect Google button is greyed out** — you opened the page over plain HTTP. Use the SSH tunnel in the install
guide and browse to `http://localhost:8080/` on your laptop.

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

## Still stuck?

[Open an issue](../../../issues/new/choose) with the output of `docker compose ps` and
`docker compose logs --tail 100`. Don't paste the contents of `./secrets` or `./data`.
