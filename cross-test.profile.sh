# SPDX-License-Identifier: MIT
# 32-bit targets build 32-bit generators; `-fqemu` runs them when the host
# kernel lacks native 32-bit execution.

CROSS_BUILD_STEP=test
CROSS_BUILD_ARGS=(-fqemu)
CROSS_BUILD_JOBS=8
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=1800