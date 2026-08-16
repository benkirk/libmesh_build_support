# libmesh_build_support -- relocatable shared-library stack.
#
# See docs/DESIGN.md for the design.  Quick start:
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

# PKG_STAGE splits the discovered packages into those 'make build' pulls in and
# those that only build when named.  See docs/EXTENDING.md.
BUILD_PKGS := $(foreach p,$(PKGS),$(if $(filter build,$(PKG_STAGE_$(p))),$(p)))
OPT_PKGS   := $(filter-out $(BUILD_PKGS),$(PKGS))

include mk/stages.mk
