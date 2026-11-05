# FamHomeBase for Raspberry Pi

Everything you need to **run** FamHomeBase on a Raspberry Pi (or any 64-bit Linux machine with Docker): a
`docker-compose.yml`, a key-generation script and the setup docs. No application code lives here.

- **[Install guide](docs/INSTALL.md)**
- **[Troubleshooting](docs/TROUBLESHOOTING.md)**
- **Problems or questions?** [Open an issue](../../issues/new/choose)

## Quick start

```bash
git clone https://github.com/mcesolutionsinc/famhomebase-pi.git
cd famhomebase-pi
./scripts/generate-key.sh      # once — then back the key up
docker compose up -d
```

- Set it up from a phone or laptop: `http://<pi-address>:8080/` (set an admin PIN first)
- The Pi's screen: `http://localhost:8080/?kiosk=1`
- Update: `docker compose pull && docker compose up -d`

Your settings live in `./data` and your encryption key in `./secrets/dashboard.key`. Back up both, separately.

## License

The files in this repository (the compose file, the script and the docs) are MIT licensed — see [LICENSE](LICENSE).
That license covers only what's in this repository. The FamHomeBase app and the container images it pulls are not
included in it and remain MC eSolutions Inc's.
