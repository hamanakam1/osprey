#!/bin/sh
# Runs the Osprey test suite.
#
# On a machine with the full Xcode toolchain, plain `swift test` works. When
# only the Command Line Tools are installed, the Swift Testing macro plugin
# lives in a subdirectory that Swift Package Manager does not search, so it is
# pointed at explicitly here.
set -e

PLUGIN_DIR="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
PLUGIN="$PLUGIN_DIR/libTestingMacros.dylib"

if [ -f "$PLUGIN" ]; then
  exec swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
fi

exec swift test "$@"
