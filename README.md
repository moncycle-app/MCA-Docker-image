# moncycle.app image

Everything that builds and runs the image of [moncycle.app](https://www.moncycle.app): one Docker image holding the API
(the `MCA-backend-and-API` repository) and the web app (the `MCA-web-APP` repository), served by one Apache.

| Where | What |
|---|---|
| `/var/www/html` | the backend (`www_data/` of the MCA-backend-and-API repository): API, scripts, libraries, config |
| `/var/www/webapp` | the web app (`src/` of the MCA-web-APP repository), Apache's `DocumentRoot`; no PHP runs there |

Apache serves the web app at `/` and reaches the backend through `Alias` lines: `/api`, `/script` (this machine only,
`APP_SCRIPT_ALLOW`), the Swagger UI files. `lib/`, `config*.php`, `constants.php` and the other `vendor/` trees have no address.

## Build

The three repositories sit side by side (`MCA-backend-and-API/`, `MCA-web-APP/`, `MCA-Docker-image/`):

```sh
./build.sh                                   # image jeanio/moncycle.app, linux/amd64
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

## Run

Copy [`docker-compose.exemple.yml`](docker-compose.exemple.yml), set `APP_URL` (with a trailing `/`), the `DB_*` and `SMTP_*` variables
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

The web app reads `/config.json`: by default `{"apiUrl": "/api/v2"}` (this image's API). Bind-mount your own file read-only on
`/var/www/webapp/config.json` to point it elsewhere.

Cron by hand: `docker exec -u www-data <container> php /var/www/html/script/cron.php`.

## Development

Use `dev.env` (copy of `dev.env.example`) as `env_file`, and bind-mount the sources over the code of the image:
`MCA-backend-and-API/www_data` on `/var/www/html` and `MCA-web-APP/src` on `/var/www/webapp` (run `npm ci` in `MCA-web-APP/` first: it makes `src/vendor/`).
Two trees are mounted separately because one mount over the other would put mount points inside a repository.

## Limits

The code is root-owned and read-only; the container needs no write access but for its log volume (`/var/log/moncycle`). Memory,
workers and the body limit are coupled (`REQUEST_BODY_MAX_BYTES`, `memory_limit`, `mem_limit`): see the comments of the compose file.

## License

AGPL-3.0-or-later, see `LICENSE`.
