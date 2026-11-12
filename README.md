# Sure (Finances) add-on for Home Assistant

Runs [Sure](https://github.com/we-promise/sure), a self-hosted personal finance application, as a self-contained Home Assistant add-on. PostgreSQL 16 and Redis are bundled, so there is nothing else to install.

## Install

1. In Home Assistant, open **Settings > Add-ons > Add-on Store > ⋮ > Repositories** and add:

   ```
   https://github.com/AlexKnowsIt/sure-hass
   ```

2. Install **Sure (Finances)** and start it.
3. Open `http://homeassistant.local:1234` (or use the **Open Web UI** button) and create your account.
4. Restrict registration: set `onboarding_state` to `closed` in the add-on options, or change it under **Settings > Self-Hosting** in Sure.

Enable **Auto update** on the add-on and **Back up before update** in Home Assistant's update settings.

See [sure/README.md](sure/README.md) for options, backups, restore and security notes.

## Updates

A single workflow (`.github/workflows/build.yaml`) runs weekly. When upstream Sure publishes a new stable release, it builds the image for amd64 and aarch64, smoke-tests it (first start, restart on the same data, pre-migration dump), pushes it to GHCR and only then bumps the version in `main`. Nothing is published unless the smoke test passes.

One-time setup for a fork:

- Enable GitHub Actions and the scheduled workflow.
- After the first publish, make the two GHCR packages (`amd64-sure-homeassistant`, `aarch64-sure-homeassistant`) public, otherwise Home Assistant cannot pull them.
- GitHub disables scheduled workflows after 60 days without repository activity. Re-enable it, or trigger the workflow manually, if that happens.

## Why no ingress

Sure does not support serving from a sub-path, which Home Assistant ingress requires. The add-on is reached directly on port 1234 instead.

## Credits and license

Originally created by [imcvampire/sure-hass](https://github.com/imcvampire/sure-hass). Licensed under the GNU Affero General Public License v3.0.
