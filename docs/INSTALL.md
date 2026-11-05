# Install guide

From a fresh Pi to a working dashboard. This covers installing and running it; how to use the dashboard is a separate guide.

## 1. What you need

- A Raspberry Pi 4 or 5 running a **64-bit** OS (Raspberry Pi OS 64-bit works), or any 64-bit Linux machine
- [Docker Engine](https://docs.docker.com/engine/install/) and the Compose plugin
  (on Raspberry Pi OS: `sudo apt install docker-compose-plugin`)
- A screen, and Chromium on the Pi

## 2. Get the files

```bash
git clone https://github.com/mcesolutionsinc/famhomebase-pi.git
cd famhomebase-pi
```

## 3. Create the encryption key

```bash
./scripts/generate-key.sh
```

This creates `./secrets/dashboard.key`, which encrypts your connected-account tokens on disk.

> **Back this key up, separately from `./data`.** If you lose it you keep your layout and settings but have to
> reconnect your calendars. The script refuses to overwrite an existing key on purpose.

## 4. Start it

```bash
docker compose up -d
docker compose ps          # both services should be healthy
docker compose logs -f
```

The first start downloads two images: the app and a small background service that stores your settings.

## 5. Set it up from another device

On a phone or laptop on the same network, open `http://<pi-address>:8080/` (find the address with `hostname -I` on
the Pi). Without `?kiosk=1` you get the full interface: customize the layout, connect calendars, change settings.
Changes are saved on the Pi, so the display picks them up.

> **Set an admin PIN first** (Settings → Admin Access). Without one, anyone on your network can change your
> dashboard. The connection is plain HTTP on your home network, so the PIN isn't encrypted in transit — don't reuse
> one you use elsewhere.

## 6. Show it on the Pi's screen

The display is the same page with `?kiosk=1`, which hides the menu:

```bash
chromium-browser --kiosk --noerrdialogs --disable-infobars "http://localhost:8080/?kiosk=1"
```

To start it automatically at login, add that command to your desktop session's autostart. Where that lives depends
on your OS version — on current Raspberry Pi OS it is typically `~/.config/labwc/autostart` (Wayland) or
`~/.config/lxsession/LXDE-pi/autostart` (older X11 installs).

## 7. Start on boot

The containers use `restart: unless-stopped`, so they return after a reboot as long as Docker does:

```bash
sudo systemctl enable docker
```

## Updating

```bash
docker compose pull
docker compose up -d
```

Your settings live in `./data` and are never touched by an update.

## Backups

Back up **both** `./data` and `./secrets/dashboard.key`, and keep the key somewhere other than the same disk.

## Uninstalling

```bash
docker compose down        # keeps ./data and ./secrets
docker compose down -v     # also removes the internal socket volume (not your data)
```
