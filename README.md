# FamHomeBase for Raspberry Pi

Everything you need to **run** the FamHomeBase wall display on a Raspberry Pi (or any 64-bit Linux machine with Docker and systemd): the
installer, the scripts that start and update the display, and the docs. No application code lives here: the display is a container image,
`ghcr.io/mcesolutionsinc/famhomebase-pi`, built from the app repo.

- **[Install guide](docs/INSTALL.md)**
- **[Troubleshooting](docs/TROUBLESHOOTING.md)**
- **Problems or questions?** [Open an issue](../../issues/new/choose)

## Quick start

**Starting with a blank memory card (Raspberry Pi 4 or 5)?** Write the ready-made image with Raspberry Pi Imager: see
[the easy way](docs/INSTALL.md#the-easy-way-a-ready-made-system-image-raspberry-pi-4-or-5). Nothing else to install.

**Already running Raspberry Pi OS?** On a Raspberry Pi (or any 64-bit Linux machine) that already has Docker:

```bash
curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sudo sh -s -- --kiosk
```

That downloads the newest release, pulls the display image and shows the display full-screen at boot. The screen shows a QR code and a code:
scan the QR code with your phone, sign in on the FamHomeBase website, name the device and pick a display. Your layout appears within seconds, and
follows every edit you make on the website.

**It updates itself.** A systemd timer checks for new releases every few hours, installs them (the image and these scripts together), and puts
the old version back if the new one doesn't come up healthy. Turn it off with `AUTO_UPDATE=false` in `/etc/famhomebase/famhomebase.env`.

## License

The files in this repository (the scripts and the docs) are MIT licensed: see [LICENSE](LICENSE). That license covers only what's in this
repository. The FamHomeBase app and the container image are not included in it and remain MC eSolutions Inc's.
