#!/bin/bash
# Выпуск версии: сборка, zip и релиз на GitHub. Программы с автообновлением подхватят его при запуске.
# Версия — CFBundleShortVersionString в Resources/Info.plist. Использование: ./release.sh "Что нового"
set -euo pipefail
cd "$(dirname "$0")"

NOTES=${1:?Напиши, что нового: ./release.sh "Что нового"}
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Релиз v$VERSION уже есть — подними версию в Resources/Info.plist"; exit 1
fi

./build.sh
ZIP=build/LiveVideoSync-$VERSION.zip
rm -f "$ZIP"
ditto -c -k --keepParent build/LiveVideoSync.app "$ZIP"
gh release create "v$VERSION" "$ZIP" --title "Live Video Sync $VERSION" --notes "$NOTES"
echo "Готово: v$VERSION"
