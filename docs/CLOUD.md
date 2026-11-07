# FamHomeBase cloud display (preview)

The new line of FamHomeBase keeps your layouts in the cloud. A display is one container that shows a QR code, waits for you to
pair it from your phone, and then draws the layout you made on the website. It runs beside, not instead of, a current Pi: the
images, the compose file and the branch are all separate.

> **Status:** preview, for testing. The container is tried on a normal computer's Docker. The Pi-only pieces (the kiosk's saved
> Chromium profile, a Pi installer for this line) are written and tested with stand-ins but **have not been run on a real Pi**;
> that is checked at the swap-over.

## Try it (staging)

You need Docker. Either build the image from the app repo's `famhomebase-cloud` branch:

```sh
git clone -b famhomebase-cloud https://github.com/mcesolutionsinc/famhomebase-app.git
docker build -f famhomebase-app/mobile/Dockerfile.cloud -t famhomebase-pi-cloud:local famhomebase-app/mobile
```

...or use a published one (`ghcr.io/mcesolutionsinc/famhomebase-pi-cloud:<version>`, made by a `cloud-vX.Y.Z` tag on the app repo).

Then one line, pointed at staging (swap in the staging site's address from the owner):

```sh
docker run -d --name famhomebase-display --restart unless-stopped -p 8080:8080 \
  -e FAMHOMEBASE_API_URL=https://<the staging site address> -e FAMHOMEBASE_ENV=staging famhomebase-pi-cloud:local
```

Open <http://localhost:8080/>. You will see a QR code and a code like `K7QM-4T9X`. On your phone scan the QR (or open
`<site address>/app/pair` and type the code), sign in, name the device and pick a display. The screen changes to your layout
within a few seconds of pairing.

The same with compose: `FAMHOMEBASE_CLOUD_IMAGE=famhomebase-pi-cloud FAMHOMEBASE_CLOUD_VERSION=local FAMHOMEBASE_API_URL=... FAMHOMEBASE_ENV=staging docker compose -f docker-compose.cloud.yml up -d`.

| Setting                | Meaning                                                                                       | Default                                  |
| ---------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `FAMHOMEBASE_API_URL`  | where the cloud is, as `https://host` with no path; the QR code points phones there too       | `https://famhomebase.mc-esolutions.ca`   |
| `FAMHOMEBASE_ENV`      | `prod` or `staging` (staging shows a STAGING banner)                                          | `prod`                                   |
| `FAMHOMEBASE_PORT`     | the port you browse to (compose only)                                                         | `8080`                                   |

A bad value stops the container at start with one JSON line saying why; the cloud's address is looked up again every 30 seconds, and a start with no DNS still comes up (`docker logs famhomebase-display`).

## What it keeps, and what to expect

- The display's secret and its last layout live in the **browser's** saved data, not in the container. Open the page in the same
  browser (and, on a Pi, the kiosk's saved profile, see `FAMHOMEBASE_PROFILE` in `scripts/kiosk.sh`) and it stays paired across
  restarts. A new browser, or removing the device on the website's Devices page, shows a new code.
- With no internet it keeps showing the last layout it had; a first start with no internet shows "Connecting".
- After that it checks for a change to its layout about once a minute, so an edit on the website shows within about a minute.
- **Agenda and meal plan are empty** for now: Google Calendar moves to the cloud in a later step.
- Pairing codes change every 10 minutes. A display nobody sets up stops asking after 24 hours and says "Restart this device to set it up."
