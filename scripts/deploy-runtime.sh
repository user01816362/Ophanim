#!/bin/bash
# Shim: moved to deploy/. Kept for backwards compat.
exec \"$(dirname \"$0\")/deploy/deploy-runtime.sh\" \"$@\"
