#!/bin/sh
# Builds the one image of moncycle.app from the backend and the web app (sibling folders by default).
#   ./build.sh [--backend DIR] [--webapp DIR] [--backend-ref URL@REF] [--webapp-ref URL@REF] [--tag NAME] [--platform P]
#   --platform: amd64, arm64, both, or a comma list (linux/ prefix optional); default: the architecture of this machine.
#   Several platforms give one image per platform, tagged NAME-amd64 and NAME-arm64 (a single one is tagged NAME).
# Without --backend/--webapp, a sibling folder is used if it exists; otherwise (and without --backend-ref/--webapp-ref) the stable
# branch is cloned (and kept up to date) in MCA-backend-and-API/ and MCA-web-APP/ next to this script (gitignored).
# The source trees are only read: build.sh stages a copy of the files git knows (tracked, or new and not ignored: modified files
# included, local config.php, vendor/ and test files left out) and gives the commits and the date as build arguments. The Dockerfile
# refuses the pair when the backend's APP_VERSION is outside the range of src/version.json of the web app, then builds the web app
# (scripts/build.mjs, esbuild from npm ci) from the staged package files, scripts/ and src/: nothing else is needed.
set -eu

BACKEND_GIT_URL="https://github.com/moncycle-app/MCA-backend-and-API"
WEBAPP_GIT_URL="https://github.com/moncycle-app/MCA-web-app"
STABLE_BRANCH="stable"

here=$(cd "$(dirname "$0")" && pwd)
backend=""
webapp=""
backend_ref=""
webapp_ref=""
tag="jeanio/moncycle.app"
platform=""

while [ $# -gt 0 ]; do
	case "$1" in
		--backend) backend="$2"; shift 2 ;;
		--webapp) webapp="$2"; shift 2 ;;
		--backend-ref) backend_ref="$2"; shift 2 ;;
		--webapp-ref) webapp_ref="$2"; shift 2 ;;
		--tag) tag="$2"; shift 2 ;;
		--platform) platform="$2"; shift 2 ;;
		-h|--help) sed -n 2,10p "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

if [ -z "$platform" ]; then
	case "$(uname -m)" in
		arm64|aarch64) platform="arm64" ;;
		x86_64|amd64) platform="amd64" ;;
		*) echo "unsupported machine architecture $(uname -m), use --platform" >&2; exit 1 ;;
	esac
fi
[ "$platform" != "both" ] || platform="amd64,arm64"
platforms=""
for p in $(echo "$platform" | tr ',' ' '); do
	p="${p#linux/}"
	case "$p" in
		amd64|arm64) ;;
		*) echo "unsupported platform: $p (amd64 or arm64)" >&2; exit 2 ;;
	esac
	case " $platforms " in *" $p "*) ;; *) platforms="$platforms $p" ;; esac
done
set -- $platforms
multi=0; [ $# -le 1 ] || multi=1

work=$(mktemp -d "${TMPDIR:-/tmp}/moncycle_build.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

# URL@REF: cloned to a temporary folder (for a CI that has remotes); the folder is then used like a local one
clone() {
	url="${1%@*}"; ref="${1##*@}"
	git clone -q "$url" "$2" && git -C "$2" checkout -q "$ref"
}
[ -z "$backend_ref" ] || { clone "$backend_ref" "$work/backend_src"; backend="$work/backend_src"; }
[ -z "$webapp_ref" ] || { clone "$webapp_ref" "$work/webapp_src"; webapp="$work/webapp_src"; }

# no folder given and no ref: the sibling folder if there is one, else a local clone of the stable branch
# default_source URL SIBLING CLONE_DIR: prints the folder to build from
default_source() {
	if [ -d "$2" ]; then echo "$2"; return; fi
	if [ -d "$3/.git" ]; then
		git -C "$3" fetch -q origin "$STABLE_BRANCH" && git -C "$3" checkout -q "$STABLE_BRANCH" && git -C "$3" merge -q --ff-only "origin/$STABLE_BRANCH" >&2 \
			|| echo "warning: could not update $3, building it as it is" >&2
	else
		git clone -q -b "$STABLE_BRANCH" "$1" "$3" >&2
	fi
	echo "$3"
}
[ -n "$backend" ] || [ -n "$backend_ref" ] || backend=$(default_source "$BACKEND_GIT_URL" "$here/../MCA-backend-and-API" "$here/MCA-backend-and-API")
[ -n "$webapp" ] || [ -n "$webapp_ref" ] || webapp=$(default_source "$WEBAPP_GIT_URL" "$here/../MCA-web-APP" "$here/MCA-web-APP")

for dir in "$backend" "$webapp"; do
	[ -d "$dir/.git" ] || { echo "not a git repository: $dir" >&2; exit 1; }
	[ -z "$(git -C "$dir" status --porcelain)" ] || echo "warning: $dir has uncommitted changes, they are built as they are" >&2
done
backend=$(cd "$backend" && pwd)
webapp=$(cd "$webapp" && pwd)

# stage DIR DEST PATHSPEC...: the files git knows, without those deleted from the working tree
stage() {
	dir="$1"; dest="$2"; shift 2
	mkdir -p "$dest"
	(cd "$dir" && git ls-files -z --cached --others --exclude-standard -- "$@" \
		| perl -e '$/ = "\0"; while (<STDIN>) { chomp; print "$_\0" if -e $_ }' \
		| tar -c --null -T - -f -) | tar -x -C "$dest" -f -
}
stage "$backend" "$work/backend" www_data
stage "$webapp" "$work/webapp" package.json package-lock.json scripts src

backend_commit=$(git -C "$backend" rev-parse --short=8 HEAD)
webapp_commit=$(git -C "$webapp" rev-parse --short=8 HEAD)
backend_version=$(git -C "$backend" describe --tags --always 2>/dev/null || echo "$backend_commit")
webapp_version=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$work/webapp/src/version.json" 2>/dev/null \
	|| sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$work/webapp/src/version.json")
build_date=$(date -u +%Y-%m-%d)

# informational audits, never blocking (through docker: neither composer nor npm is needed on this machine)
if command -v composer >/dev/null 2>&1; then (cd "$work/backend/www_data" && composer audit) || true
else docker run --rm -v "$work/backend/www_data:/app" composer/composer:latest audit || true; fi
docker run --rm -v "$work/webapp:/app" -w /app node:24-alpine npm audit --omit=dev || true

for p in $platforms; do
	image="$tag"; [ "$multi" -eq 0 ] || image="$tag-$p"
	docker buildx build \
		--platform "linux/$p" \
		--build-context backend="$work/backend" \
		--build-context webapp="$work/webapp" \
		--build-arg BACKEND_COMMIT="$backend_commit" \
		--build-arg WEBAPP_COMMIT="$webapp_commit" \
		--build-arg BACKEND_VERSION="$backend_version" \
		--build-arg WEBAPP_VERSION="$webapp_version" \
		--build-arg BUILD_DATE="$build_date" \
		--load \
		-t "$image" \
		"$here"
	echo "built $image (linux/$p): backend $backend_version ($backend_commit), web app $webapp_version ($webapp_commit), $build_date"
done
