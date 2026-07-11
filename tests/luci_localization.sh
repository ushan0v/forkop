#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"
SOURCE_PO="$ROOT_DIR/fe-app-forkop/locales/forkop.ru.po"
PACKAGE_PO="$ROOT_DIR/luci-app-forkop/po/ru/forkop.po"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if grep -Fq '_("Dismiss")' "$SECTION_JS"; then
  fail "Forkop modals must use Close instead of the shared LuCI Dismiss key"
fi
grep -Fq '_("Close")' "$SECTION_JS" ||
  fail "Forkop section settings modal must expose a Close action"

for po in "$SOURCE_PO" "$PACKAGE_PO"; do
  awk '
    $0 == "msgid \"Close\"" {
      getline
      if ($0 == "msgstr \"Закрыть\"")
        found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$po" || fail "Close must be translated as Закрыть in $po"

  if awk '
    $0 == "msgid \"Dismiss\"" {
      getline
      if ($0 == "msgstr \"Отмена\"")
        bad = 1
    }
    END { exit bad ? 0 : 1 }
  ' "$po"; then
    fail "Dismiss must not override LuCI alert closing with Отмена in $po"
  fi
done

cmp -s "$SOURCE_PO" "$PACKAGE_PO" ||
  fail "source and packaged Russian catalogs must stay synchronized"

printf 'LuCI localization checks passed\n'
