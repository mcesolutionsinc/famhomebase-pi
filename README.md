# FamHomeBase for Raspberry Pi

Everything you need to **run** FamHomeBase on a Raspberry Pi (or any 64-bit Linux machine with Docker): a
`docker-compose.yml`, a key-generation script and the setup docs. No application code lives here.

- **[Install guide](docs/INSTALL.md)**
- **[Troubleshooting](docs/TROUBLESHOOTING.md)**
- **Problems or questions?** [Open an issue](../../issues/new/choose)

## Quick start

On a Raspberry Pi (or any 64-bit Linux machine) that already has Docker:

```bash
curl -fsSL https://github.com/mcesolutionsinc/famhomebase-pi/releases/latest/download/install.sh | sh
```

That downloads the latest release, creates your encryption key and starts everything. Then:

- Set it up from a phone or laptop: `http://<pi-address>:8080/` (it asks you to set an admin PIN first)
- The Pi's screen: `http://localhost:8080/?kiosk=1`
- **It updates itself.** A small `updater` service checks for new releases every few hours, installs them, and rolls back
  if one doesn't start. Turn it off with `AUTO_UPDATE=false` in `.env`. Details in the [install guide](docs/INSTALL.md).

Your settings live in `~/famhomebase-pi/data` and your encryption key in `~/famhomebase-pi/secrets/dashboard.key`. Back up both, separately.

## License

The files in this repository (the compose file, the script and the docs) are MIT licensed — see [LICENSE](LICENSE).
That license covers only what's in this repository. The FamHomeBase app and the container images it pulls are not
included in it and remain MC eSolutions Inc's.
