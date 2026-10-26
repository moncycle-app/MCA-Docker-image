#!/bin/sh
# Builds the one image of moncycle.app from the backend and the web app (sibling folders by default).
#   ./build.sh [--backend DIR] [--webapp DIR] [--backend-ref URL@REF] [--webapp-ref URL@REF] [--tag NAME] [--platform P]
# The source trees are only read: build.sh stages a copy of the files git knows (tracked, or new and not ignored: modified files
# included, local config.php, vendor/ and test files left out) and gives the commits and the date as build arguments. The Dockerfile
# refuses the pair when the backend's APP_VERSION is outside the range of src/version.json of the web app.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
backend="$here/../MCA-backend-and-API"
webapp="$here/../MCA-web-APP"
backend_ref=""
webapp_ref=""
tag="jeanio/moncycle.app"
platform="linux/amd64"

while [ $# -gt 0 ]; do
	case "$1" in
		--backend) backend="$2"; shift 2 ;;
		--webapp) webapp="$2"; shift 2 ;;
		--backend-ref) backend_ref="$2"; shift 2 ;;
		--webapp-ref) webapp_ref="$2"; shift 2 ;;
		--tag) tag="$2"; shift 2 ;;
		--platform) platform="$2"; shift 2 ;;
		-h|--help) sed -n 2,7p "$0"; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

work=$(mktemp -d "${TMPDIR:-/tmp}/moncycle_build.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

# URL@REF: cloned to a temporary folder (for a CI that has remotes); the folder is then used like a local one
clone() {
	url="${1%@*}"; ref="${1##*@}"
	git clone -q "$url" "$2" && git -C "$2" checkout -q "$ref"
}
[ -z "$backend_ref" ] || { clone "$backend_ref" "$work/backend_src"; backend="$work/backend_src"; }
[ -z "$webapp_ref" ] || { clone "$webapp_ref" "$work/webapp_src"; webapp="$work/webapp_src"; }

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

docker buildx build \
	--platform "$platform" \
	--build-context backend="$work/backend" \
	--build-context webapp="$work/webapp" \
	--build-arg BACKEND_COMMIT="$backend_commit" \
	--build-arg WEBAPP_COMMIT="$webapp_commit" \
	--build-arg BACKEND_VERSION="$backend_version" \
	--build-arg WEBAPP_VERSION="$webapp_version" \
	--build-arg BUILD_DATE="$build_date" \
	--load \
	-t "$tag" \
	"$here"
echo "built $tag: backend $backend_version ($backend_commit), web app $webapp_version ($webapp_commit), $build_date"
