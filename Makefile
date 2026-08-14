# libmesh_build_support -- relocatable shared-library stack.
#
# See docs/RELOCATABLE-STACK-PLAN.md for the design.  Quick start:
#
#   cp config.mk.example config.mk     # then edit
#   make conda build test relocate validate dist distcheck
#
# 'make help' lists every target; 'make print-config' shows resolved settings.

.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
.SUFFIXES:

# 1. user overrides, 2. defaults + machinery, 3. version profile
-include config.mk
include mk/common.mk
include profiles/$(PROFILE).mk
include mk/pkg.mk

#-------------------------------------------------------------------------------
# Package discovery.  pkgs/ ships the defaults; SITE_DIRS is where customers
# drop their own recipes without touching anything tracked here.
PKG_MKS := $(sort $(wildcard pkgs/*/pkg.mk)) \
           $(sort $(foreach d,$(SITE_DIRS),$(wildcard $(d)/*/pkg.mk)))

# _template is documentation, not a package.
PKG_MKS := $(filter-out pkgs/_template/pkg.mk,$(PKG_MKS))

PKGS :=
$(foreach m,$(PKG_MKS),$(eval pkg_dir := $(dir $(m)))$(eval include $(m)))
$(foreach p,$(PKGS),$(eval $(call PKG_RULE,$(p))))

include mk/stages.mk
