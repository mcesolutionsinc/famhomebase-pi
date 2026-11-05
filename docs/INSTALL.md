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

The first time you open it, it asks you to **set an admin PIN** before showing anything. Without one, anyone on your
network could change your dashboard. After that, viewing the dashboard needs no PIN, but Customize, Accounts and
Settings ask for it. The Pi's own screen (`?kiosk=1`) never asks. The connection is plain HTTP on your home
network, so the PIN isn't encrypted in transit — don't reuse one you use elsewhere.

## 6. Show it on the Pi's screen

The display is the same page with `?kiosk=1`, which hides the menu. First check the browser's name on your system:

```bash
which chromium chromium-browser
```

On Raspberry Pi OS based on Debian 13 ("trixie") the command is `chromium`; older releases use `chromium-browser`. Try it once by hand from a terminal **on the Pi's desktop**:

```bash
chromium --kiosk --noerrdialogs --disable-infobars --no-first-run "http://localhost:8080/?kiosk=1"
```

(Close it with Alt+F4.) To start it automatically at login:

1. Make the Pi log into the desktop by itself: `sudo raspi-config` → System Options → Boot / Auto Login → **Desktop Autologin**. Without a desktop session nothing autostarts.
2. On current Raspberry Pi OS the desktop is `labwc` (Wayland). Create `~/.config/labwc/autostart`:

   ```bash
   mkdir -p ~/.config/labwc
   cat > ~/.config/labwc/autostart <<'EOF'
   # Wait for the dashboard to be up, then open it full-screen on the Pi's display.
   sh -c 'until curl -sf http://localhost:8080/ >/dev/null; do sleep 2; done; B=$(command -v chromium || command -v chromium-browser); exec "$B" --kiosk --noerrdialogs --disable-infobars --no-first-run "http://localhost:8080/?kiosk=1"' &
   EOF
   ```

   The wait matters: without it the browser can start before Docker has the dashboard up and land on an error page. A command that fails in this file fails silently, which is why testing it by hand first is worth the minute. Older X11-based installs use `~/.config/lxsession/LXDE-pi/autostart` instead.
3. Log out and back in, or reboot.

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
