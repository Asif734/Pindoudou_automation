#!/bin/zsh
set -euo pipefail

PACKAGE_ROOT="${1:?usage: delivery_source_cleanliness_test.sh <delivery-package-directory>}"
SOURCE_ROOT="$PACKAGE_ROOT/05-完整源码"

test -d "$SOURCE_ROOT/Tools/PDDVideoDirectProbe"

for generated in \
  "$SOURCE_ROOT/Tools/PDDVideoDirectProbe/dist" \
  "$SOURCE_ROOT/Tools/PDDVideoDirectProbe/backups"; do
  if [[ -e "$generated" ]]; then
    print -u2 -- "交付源码包含不应打包的旧生成物：$generated"
    exit 1
  fi
done

print "交付源码清洁度测试通过"
