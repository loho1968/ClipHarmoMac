#!/bin/bash
# 进入 Package.swift 所在目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PACKAGE_DIR"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build
swift run ClipboardSync
