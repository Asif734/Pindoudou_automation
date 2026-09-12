# Bundled Python Runtime

The PDD auto-reply application bundles an Apple Silicon CPython 3.12 runtime from
[`astral-sh/python-build-standalone`](https://github.com/astral-sh/python-build-standalone).

- Asset: `cpython-3.12.14+20260825-aarch64-apple-darwin-install_only_stripped.tar.gz`
- Release: `20260825`
- SHA-256: `8b0f1fa71eab7ca644e482c631807a1116fa848491051cd1c8d9429491de63a6`
- Project license: MPL-2.0

The archive is verified before staging. The shipped application never downloads or installs Python at runtime.
