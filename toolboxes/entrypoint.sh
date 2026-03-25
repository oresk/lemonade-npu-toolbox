#!/bin/bash
set -e

# Check NPU device
if [ ! -c /dev/accel/accel0 ]; then
    echo "WARNING: /dev/accel/accel0 not found — did you pass --device /dev/accel/accel0?"
    echo "         NPU inference will not work without the device."
fi

# Check memlock limit — FastFlowLM requires unlimited memlock
MEMLOCK=$(ulimit -l 2>/dev/null || echo "0")
if [ "$MEMLOCK" != "unlimited" ]; then
    echo "WARNING: memlock limit is '${MEMLOCK}' (should be 'unlimited')."
    echo "         Pass --ulimit memlock=-1:-1 to the container runtime."
fi

exec "$@"
