#!/bin/zsh
set -euo pipefail

if [[ $# -ne 3 ]]; then
    print -u2 "用法：$0 <runtime.tar.gz> <sha256> <destination>"
    exit 64
fi

archive="$1"
expected_sha256="$2"
destination="$3"

test -f "$archive" || { print -u2 "Python 运行时归档不存在：$archive"; exit 1; }
[[ "$expected_sha256" =~ '^[0-9a-f]{64}$' ]] || {
    print -u2 "Python 运行时 SHA-256 格式无效"
    exit 1
}
[[ -n "$destination" && "$destination" != "/" ]] || {
    print -u2 "拒绝使用危险的 Python 运行时目标目录"
    exit 1
}
test ! -e "$destination" || {
    print -u2 "Python 运行时目标目录已存在：$destination"
    exit 1
}

actual_sha256="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha256" == "$expected_sha256" ]] || {
    print -u2 "Python 运行时 SHA-256 不匹配"
    exit 1
}

staging_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pdd-python-runtime.XXXXXX")"
trap '/bin/rm -rf -- "$staging_root"' EXIT
/usr/bin/tar -xzf "$archive" -C "$staging_root"
test -x "$staging_root/python/bin/python3" || {
    print -u2 "Python 运行时归档缺少 python/bin/python3"
    exit 1
}
/bin/mkdir -p "$destination"
/bin/mv "$staging_root/python" "$destination/python"
