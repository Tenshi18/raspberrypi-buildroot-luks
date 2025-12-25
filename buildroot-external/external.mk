# Buildroot external.mk for LUKS encryption support
#
# This file is included by Buildroot's makefile system when using BR2_EXTERNAL
#

# Include package makefiles
include $(sort $(wildcard $(BR2_EXTERNAL_LUKS_PI_PATH)/package/*/*.mk))

