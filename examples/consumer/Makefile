# Consumer wrapper -- build your packages on top of the libMesh stack.
#
# This is the ENTIRE top-level Makefile a customer needs.  Their repository is
# the top level; this project is vendored as a git submodule at build_support/;
# their packages live in packages/<name>/{pkg.mk,build.sh}.  Everything else --
# the toolchain, the base stack (PETSc/libMesh/Trilinos), relocation, validation
# and packaging -- comes from the submodule.
#
#   git submodule update --init build_support
#   make PROFILE=stable all
#
# 'make help' lists every target (forwarded from the submodule); any VAR=value
# you pass on the command line (PROFILE, V, BLAS_PROVIDER, ...) propagates to the
# submodule automatically.
#
# How it works: every goal is forwarded verbatim to a single sub-make in the
# submodule, with SITE_DIRS pointed back at your packages/ and the build-root /
# dist paths redirected OUT of the submodule so it stays a clean checkout.

# Override on the command line or in the environment if your layout differs.
BUILD_SUPPORT ?= build_support
PKGS_DIR      ?= $(CURDIR)/packages
BUILD_ROOT    ?= $(CURDIR)/_root
DIST_DIR      ?= $(CURDIR)/dist

# The overrides handed to the submodule on every invocation.  SITE_DIRS is the
# submodule's existing extension point (default 'site'); here it names your
# packages/ instead.  BUILD_ROOT and DIST_DIR default INSIDE the submodule
# (mk/common.mk), so they must be redirected or the build would write artifacts
# and the tarball into the submodule checkout.
FORWARD = SITE_DIRS='$(PKGS_DIR)' BUILD_ROOT='$(BUILD_ROOT)' DIST_DIR='$(DIST_DIR)'

# Fail early and legibly if the submodule was never checked out -- otherwise the
# first symptom is an inscrutable 'No rule to make target' from an empty dir.
ifeq ($(wildcard $(BUILD_SUPPORT)/Makefile),)
$(error $(BUILD_SUPPORT)/ is empty -- run: git submodule update --init $(BUILD_SUPPORT))
endif

# Forward whatever goals were named (or 'help' if none) to ONE sub-make.  Each
# goal depends on the same phony forwarder, which make coalesces to a single
# invocation, so 'make clean all' runs the submodule once with both goals in
# order rather than once per goal.
GOALS := $(or $(MAKECMDGOALS),help)

.PHONY: $(GOALS) __forward
$(GOALS): __forward
	@:
__forward:
	$(MAKE) -C $(BUILD_SUPPORT) $(FORWARD) $(GOALS)
