################################################################################
#
# tg-lbench: the Linux workload set (DR-141; docs/spec/verification.md §4.6), built from
# tests/bench/linux with the image's toolchain. CoreMark and Dhrystone come from
# perfmodel/third_party (perfmodel/scripts/fetch_deps.sh), as for the bare-metal runs.
#
################################################################################

TG_LBENCH_VERSION = local
TG_LBENCH_SITE = $(BR2_EXTERNAL_TANAGER_PATH)/../../tests/bench/linux
TG_LBENCH_SITE_METHOD = local

# Built from the repository's tree (its Makefile finds perfmodel/ from there), outputs in the build dir.
TG_LBENCH_SRC = $(BR2_EXTERNAL_TANAGER_PATH)/../../tests/bench/linux

define TG_LBENCH_BUILD_CMDS
	$(MAKE) -C $(TG_LBENCH_SRC) CC="$(TARGET_CC)" OUT=$(@D)/out
endef

define TG_LBENCH_INSTALL_TARGET_CMDS
	$(MAKE) -C $(TG_LBENCH_SRC) CC="$(TARGET_CC)" OUT=$(@D)/out DESTDIR=$(TARGET_DIR) install
endef

$(eval $(generic-package))
