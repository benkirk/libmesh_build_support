# mk/common.mk -- paths, knobs, and the package-declaration machinery.
# Included by the top-level Makefile before any package is discovered.

#-------------------------------------------------------------------------------
# Knobs.  Every one of these is overridable in config.mk or on the command line.
BUILD_ROOT      ?= $(CURDIR)/_root
PROFILE         ?= default
TARGET_PLATFORM ?= linux-64
GLIBC_FLOOR     ?= 2.28
GCC_VERSION     ?= 14
BLAS_PROVIDER   ?= openblas
MPI_FAMILY      ?= mpich
MPI_PROVIDER    ?= conda
MPI_VERSION     ?= 5.0.1
HDF5_VERSION    ?= 1.14
HDF5_PARALLEL   ?= no
RPATH_MODE      ?= rpath
# Instruction-set floor for the shipped binaries.  See amendment A21.
#
# x86-64-v2 is SSE4.2+popcnt, Nehalem/2009 and later -- the level RHEL 9 itself
# requires, so it cannot exclude a host running a current distro.
#
# armv8.1-a rather than the armv8-a baseline, because that is what we MEASURED
# the artifact to need, not what we would prefer.  conda-forge's aarch64
# toolchain emits LSE atomics inline and unguarded -- no __aarch64_have_lse
# guard, no outline-atomic helpers -- in libstdc++, libgcc_s, libgfortran,
# libcurl, libfabric, libucs and others.  Those are binaries we do not build.
# armv8.1-a is 2016+ and covers every server part (Graviton 2+, Neoverse,
# Ampere); it excludes Cortex-A72/A53/A57, i.e. Raspberry Pi 4 class hardware.
ISA_BASELINE_X86     ?= x86-64-v2
ISA_BASELINE_AARCH64 ?= armv8.1-a
# What the compiler wrappers do when a build asks for '-march=native'.  'error'
# by default: the baseline we append afterwards would neutralise it anyway, so
# stopping is about visibility -- a build detecting the host CPU is rarely doing
# it in only one place.  'warn' to get past it.  See wrappers/generate.sh.
WRAPPER_ON_NATIVE ?= error
USE_WRAPPERS      ?= yes
SLIM_PROFILE    ?= devel
SHIP_PYTHON     ?= no
SMOKE_RANKS     ?= 4
SITE_DIRS       ?= site
DIST_NAME       ?= libmesh-stack
DIST_VERSION    ?= 0.1.0

#-------------------------------------------------------------------------------
# Derived paths.  STACK is both the conda env and the install prefix -- there is
# deliberately no second prefix.  See docs/DESIGN.md.
STACK       := $(BUILD_ROOT)/stack
CONDA_HOME  := $(BUILD_ROOT)/.conda
WORK        := $(BUILD_ROOT)/.work
STAMPS      := $(WORK)/stamps
SRC_CACHE   ?= $(WORK)/src
LOGS        := $(WORK)/logs
DIST_DIR    ?= $(CURDIR)/dist

CONDA       := $(CONDA_HOME)/bin/conda
export CONDARC        := $(CONDA_HOME)/condarc
export CONDA_PKGS_DIRS ?= $(CONDA_HOME)/pkgs

ISA_BASELINE := $(if $(filter linux-aarch64,$(TARGET_PLATFORM)),$(ISA_BASELINE_AARCH64),$(ISA_BASELINE_X86))

TARBALL := $(DIST_DIR)/$(DIST_NAME)-$(DIST_VERSION)-$(TARGET_PLATFORM)-$(BLAS_PROVIDER)-glibc$(GLIBC_FLOOR).tar.gz

#-------------------------------------------------------------------------------
# Parallelism.  Carried over from the old build_config.sh.in.
# The -l load cap is carried over from the old build_config.sh.in and matters
# on shared build hosts: -j alone will happily oversubscribe a busy machine.
NPROC       := $(shell nproc 2>/dev/null || echo 4)
MAKE_J_L    := -j $(NPROC) -l $(shell echo $$(( $(NPROC) * 2 )))
export NPROC

#-------------------------------------------------------------------------------
# Verbosity.  'make V=1' echoes recipes.
V ?= 0
ifeq ($(V),0)
  Q := @
  SAY = @printf '  %-9s %s\n'
else
  Q :=
  SAY = @printf '  %-9s %s\n'
endif

#-------------------------------------------------------------------------------
# Environment handed to every build.sh.  The contract documented in
# docs/EXTENDING.md; keep this list and that document in sync.
PKG_ENV = \
  STACK='$(STACK)' \
  WORK='$(WORK)' \
  SRC_CACHE='$(SRC_CACHE)' \
  CONDA_HOME='$(CONDA_HOME)' \
  NPROC='$(NPROC)' \
  MAKE_J_L='$(MAKE_J_L)' \
  TARGET_PLATFORM='$(TARGET_PLATFORM)' \
  BLAS_PROVIDER='$(BLAS_PROVIDER)' \
  MPI_FAMILY='$(MPI_FAMILY)' \
  RPATH_MODE='$(RPATH_MODE)' \
  ISA_BASELINE='$(ISA_BASELINE)' \
  USE_WRAPPERS='$(USE_WRAPPERS)' \
  TOPDIR='$(CURDIR)'

#-------------------------------------------------------------------------------
# declare_pkg -- called at the end of each pkgs/<name>/pkg.mk.  Snapshots the
# generic PKG_* variables into namespaced ones so many pkg.mk files can be
# included without clobbering each other, then clears them for the next include.
#
# Note what the clearing implies for a recipe author: after the first pkg.mk is
# included these names are DEFINED-but-empty, so '?=' in a later pkg.mk silently
# does nothing.  Recipes assign with ':=' and let the defaults below apply --
# which is why PKG_SOURCE defaults via $(or ...) here rather than via '?='.
define declare_pkg
PKGS                    += $(PKG_NAME)
PKG_VERSION_$(PKG_NAME) := $(PKG_VERSION)
PKG_DEPS_$(PKG_NAME)    := $(PKG_DEPS)
PKG_URL_$(PKG_NAME)     := $(PKG_URL)
PKG_DIR_$(PKG_NAME)     := $(pkg_dir)
PKG_STAGE_$(PKG_NAME)   := $(or $(PKG_STAGE),build)
PKG_SOURCE_$(PKG_NAME)  := $(or $(PKG_SOURCE),tarball)
PKG_GIT_URL_$(PKG_NAME) := $(PKG_GIT_URL)
PKG_GIT_REF_$(PKG_NAME) := $(PKG_GIT_REF)
PKG_NAME    :=
PKG_VERSION :=
PKG_DEPS    :=
PKG_URL     :=
PKG_STAGE   :=
PKG_SOURCE  :=
PKG_GIT_URL :=
PKG_GIT_REF :=
endef

#-------------------------------------------------------------------------------
# run_hooks -- executes hooks/<stage>/*.sh in sorted order, if any exist.
# Customers inject here without editing tracked files.
define run_hooks
	$(Q)if [ -d '$(CURDIR)/hooks/$(1)' ]; then \
	  for h in $(CURDIR)/hooks/$(1)/*.sh; do \
	    [ -e "$$h" ] || continue; \
	    printf '  %-9s %s\n' HOOK "$(1)/$$(basename $$h)"; \
	    env $(PKG_ENV) bash "$$h" || exit 1; \
	  done; \
	fi
endef
