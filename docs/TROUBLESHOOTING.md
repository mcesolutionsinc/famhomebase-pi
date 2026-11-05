# Troubleshooting

**The containers won't start** — `docker compose logs`. If `configstore` exits immediately, check that
`./secrets/dashboard.key` exists and is exactly 32 bytes (`./scripts/generate-key.sh` makes one).

**Port 8080 is already in use** — edit `docker-compose.yml` and change the left-hand number, e.g. `"8081:8080"`.

**Settings say "Can't reach the Pi"** — the app can't reach its background service. `docker compose ps` should show
both services healthy; try `docker compose restart configstore`.

**Settings say changes are saved here but not on the Pi, and to log in** — you've set an admin PIN. Open
Settings → Admin Access and log in; your changes then sync.

**An account says "Needs reconnect"** — Google revoked or expired the connection. Press Reconnect on the Accounts
screen and sign in again, leaving every permission box ticked.

**The display shows the full menu** — the address needs `?kiosk=1`.

Still stuck? [Open an issue](../../../issues/new/choose) with the output of `docker compose ps` and
`docker compose logs --tail 100`. Don't paste the contents of `./secrets` or `./data`.
