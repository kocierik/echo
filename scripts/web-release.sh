#!/usr/bin/env bash
# The Flutter app built for the browser, served by the api at /app (site/app).
# Each build goes in its own folder (/app/<id>/): Cloudflare keeps .js files for hours,
# so new code needs new addresses. /app/index.html, never cached, points at the newest.
set -euo pipefail
cd "$(dirname "$0")/.."

id="$(date +%Y%m%d%H%M%S)"
owner="$(id -u):$(id -g)"
docker run --rm -v echo-pub-cache:/root/.pub-cache -v "$PWD/mobile:/app" -w /app \
  ghcr.io/cirruslabs/flutter:stable sh -c "
    flutter pub get >/dev/null &&
    flutter build web --release --no-wasm-dry-run --base-href /app/$id/;
    status=\$?; chown -R $owner build .dart_tool; exit \$status"

mkdir -p "site/app/$id"
cp -r mobile/build/web/. "site/app/$id/"
cp "site/app/$id/index.html" site/app/index.html
echo "Published https://echo.man.ovh/app/ (build $id)"
