# moncycle.app image

Everything that builds and runs the image of [moncycle.app](https://www.moncycle.app): one Docker image holding the API
(the `MCA-backend-and-API` repository) and the web app (the `MCA-web-APP` repository), served by one Apache.

| Where | What |
|---|---|
| `/var/www/html` | the backend (`www_data/` of the MCA-backend-and-API repository): API, scripts, libraries, config |
| `/var/www/webapp` | the web app, built (`dist/` of `npm run build` in the MCA-web-APP repository), Apache's `DocumentRoot`; no PHP runs there |

Apache serves the web app at `/` and reaches the backend through `Alias` lines: `/api`, `/script` (this machine only,
`APP_SCRIPT_ALLOW`), the Scalar page files. `lib/`, `config*.php`, `constants.php` and the other `vendor/` trees have no address.

## Build

The three repositories sit side by side (`MCA-backend-and-API/`, `MCA-web-APP/`, `MCA-Docker-image/`):

```sh
./build.sh                                   # image jeanio/moncycle.app, for the architecture of this machine
./build.sh --platform amd64                  # or arm64
./build.sh --platform both                   # jeanio/moncycle.app-amd64 and jeanio/moncycle.app-arm64
./build.sh --tag dev_moncycle_app            # another name
./build.sh --backend ../MCA-backend-and-API --webapp ../MCA-web-APP --platform linux/arm64
./build.sh --backend-ref URL@REF --webapp-ref URL@REF   # clones them to a temporary folder (CI)
```

`build.sh` never changes the source trees: it stages a copy of the files git knows (modified files included, ignored files such as the
local `config.php` and `vendor/` left out), warns when a tree is dirty, runs `composer audit` and `npm audit` for information (through
Docker, nothing is installed on the host) and calls `docker buildx build` with the two trees as named build contexts and the
commits and date as build arguments. **The build fails when the backend is out of the range the web app supports**: the integer at
the start of `APP_VERSION` (`constants.php`) must be inside `api.min`..`api.max` of the web app's `src/version.json`. The image
carries both versions as labels (`app.moncycle.backend.version`, `app.moncycle.webapp.version`, and their commits) and `version.json`
of the web app is stamped with the build date and commit.

The web app is then built in the image (`scripts/build.mjs`, after the stamp): its scripts and styles become minified bundles with a
content hash in their name, `assets/<name>-<hash>.js` and `.css`; `index.html`, `config.json`, `version.json`, `i18n/*.json`, the fonts
and images keep their names. The build fails without `dist/index.html` or with a source map in it. Cache policy of what Apache serves:

| Files | `Cache-Control` |
|---|---|
| `/assets/<name>-<hash>.js`, `.css` | `public, max-age=31536000, immutable` (a change is a new name) |
| `index.html`, `config.json`, `version.json`, `i18n/*.json`, any other `.js`/`.css`/`.json` | `no-cache` (revalidated, `304` when unchanged) |
| fonts (`.ttf`, `.woff2`) | `public, max-age=31536000, immutable` |
| images | `public, max-age=604800` |
| `/api/` | `no-store` |
| everything, with `PHP_CACHE=Off` (dev) | `no-store` |

Text types (html, js, css, json, svg, ttf) are compressed by `mod_deflate` (`Vary: Accept-Encoding`).

## Run

Copy [`docker-compose.exemple.yml`](docker-compose.exemple.yml), set `APP_URL` (with a trailing `/`), `DB_DSN`, `SMTP_URL`
and the two secret files, then `docker compose up -d`. The container makes the schema on a first start, upgrades an older database,
runs the daily cron itself (`CRON_ENABLED`) and serves plain HTTP on port 80: put a reverse proxy with TLS in front, and set
`TRUSTED_PROXIES`. Every setting of the application is in the backend README ("Settings"). Specific to the image:

| Variable | Default | Meaning |
|---|---|---|
| `CORS_ALLOWED_ORIGINS` | – | Exact origins (spaces or commas) of a web app served apart from the API. Empty: no CORS header. Set: those origins get `Access-Control-Allow-*` on every `/api/` answer (no credentials) and an unauthenticated preflight answers `204`. Also put the origin in `WEB_APP_ORIGINS`. |
| `PHP_CACHE`, `PHP_SHOW_ERR`, `PHP_ERROR_REPORTING`, `PHP_ASSERTIONS`, `PHP_SECURE_COOKIES` | production values | PHP settings, see [`dev.env.example`](dev.env.example) for development |
| `CRON_ENABLED`, `DEMO_ENABLED` | `true`, `false` | the schedulers (daily job, hourly demo reset) |
| `APP_SCRIPT_ALLOW` | `127.0.0.1 ::1` | who may call `/script/` over HTTP |
| `CAPTCHA_SECRET` | random per start | key of the signed captcha, 32+ characters |

The web app reads `/config.json`: by default `{"apiUrl": "/api/v3"}` (this image's API). Bind-mount your own file read-only on
`/var/www/webapp/config.json` to point it elsewhere.

### Upgrading to the `/api/v3` release

**Settings that changed** (the container no longer reads the old ones): `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_ID` become the single
`DB_DSN` (`mysql:host=...;port=3306;dbname=...;user=...`), and `SMTP_HOST`, `SMTP_PORT`, `SMTP_MAIL` become `SMTP_URL`
(`smtps://login%40domain@host:465`); the password variables and `*_FILE` secrets are unchanged. The image is now PHP 8.5, and the
API documentation page is Scalar (it replaces Swagger UI). See `docker-compose.exemple.yml`.

This version needs the database migration to schema 16 (new table `user_setting`, columns dropped from `user_account`, table
`description` renamed `day_description`). The entrypoint runs `script/auto_upgrade.php` at start: **take a database dump first**.
The API moved from `/api/v2/` to `/api/v3/` (`/api/v2/` now answers 404): move every client, reverse-proxy rule (rate limits on
`/api/v3/token`, `/register`, `/recover_password`, `/verify_email`, `/captcha`), health check and custom `config.json` to `/api/v3`.

Cron by hand: `docker exec -u www-data <container> php /var/www/html/script/cron.php`.

## Development

Use `dev.env` (copy of `dev.env.example`) as `env_file`, and bind-mount the sources over the code of the image:
`MCA-backend-and-API/www_data` on `/var/www/html` and `MCA-web-APP/src` on `/var/www/webapp` (run `npm ci` in `MCA-web-APP/` first: it makes `src/vendor/`). The raw `src/` is served then, unbundled.
Two trees are mounted separately because one mount over the other would put mount points inside a repository.

## Limits

The code is root-owned and read-only; the container needs no write access but for its log volume (`/var/log/moncycle`). Memory,
workers and the body limit are coupled (`REQUEST_BODY_MAX_BYTES`, `memory_limit`, `mem_limit`): see the comments of the compose file.

## License

AGPL-3.0-or-later, see `LICENSE`.
