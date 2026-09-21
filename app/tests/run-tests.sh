#!/bin/bash
# Compiles the Foundation-only logic together with the assert-based test main
# and runs it. No SPM and no XCTest on purpose: build.sh stays untouched and
# this runs in seconds with nothing installed.
set -e
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/cub-tests"
swiftc -o "$OUT" UsageLogic.swift tests/main.swift
"$OUT"
