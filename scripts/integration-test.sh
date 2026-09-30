#!/bin/bash
# Shim: moved to test/. Kept for backwards compat.
exec \"$(dirname \"$0\")/test/integration-test.sh\" \"$@\"
