#!/bin/bash
# Copy this extension into Onecast's extensions directory — the same files ExtensionCatalog.install
# copies, and no others: package.json, one <command>.js per declared command, and assets/.
#
#   ./install.sh                     -> Onecast Dev.app (com.onecast.app.dev)
#   ./install.sh com.onecast.app    -> the installed release app

set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="${1:-com.onecast.app.dev}"
NAME="$(node -p "require('./package.json').name.replaceAll('/', '-')")"
COMMANDS="$(node -p "require('./package.json').commands.map(c => c.name).join('\n')")"
DEST="$HOME/Library/Application Support/$BUNDLE_ID/extensions/$NAME"

for command in $COMMANDS; do
    if [ ! -f "$command.js" ]; then
        echo "$command.js is missing — run \`npm run build\` first" >&2
        exit 1
    fi
done

rm -rf "$DEST"
mkdir -p "$DEST"
cp package.json "$DEST/"
for command in $COMMANDS; do cp "$command.js" "$DEST/"; done
[ -d assets ] && cp -R assets "$DEST/assets"

echo "installed $NAME (${COMMANDS//$'\n'/, }) -> $DEST"
