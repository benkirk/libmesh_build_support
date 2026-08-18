# mk/stages.mk -- the stage targets and their ordering.
# Mirrors the numbered steps in docs/DESIGN.md (the pipeline section):
#
#   1 conda -> 2 build -> 3 test -> 4 relocate -> validate -> 5 test
#                      -> 6 slim -> validate -> 7 dist -> distcheck
#
# Ordering is expressed as a real dependency graph, not as a sequence of
# sub-makes, so 'make -n all' prints the plan once and in order.
#
# The verifying stages (test, validate) appear twice each, so they get one
# stamp per position in the chain, named for what they verify.  A gate stamp
# is legitimate caching -- if nothing downstream of it changed, its verdict
# still holds -- but the plain 'make test' and 'make validate' entry points
# are phony and ALWAYS re-run, because a gate you can satisfy by not running
# it is not a gate.

.PHONY: all conda wrappers wrappers-check build test relocate validate slim \
        dist distcheck help shell image-shell clean distclean conda-lock \
        print-config

## all: the whole workflow, conda through distcheck
all: distcheck

$(BUILD_ROOT) $(STACK) $(WORK) $(STAMPS) $(LOGS) $(SRC_CACHE) $(DIST_DIR):
	$(Q)mkdir -p $@

#-------------------------------------------------------------------------------
# The two verifying actions, defined once and referenced from both the phony
# entry point and the stamped position in the chain.  $(1) is a label.
define do_test
	$(call run_hooks,pre-test)
	$(SAY) TEST '$(1)'
	$(Q)env $(PKG_ENV) SMOKE_RANKS='$(SMOKE_RANKS)' bash test/run.sh inplace
	$(call run_hooks,post-test)
endef

# $(1) is the stage label AND the validate stage: 'relocated' reports embedded
# prefix residue, 'final' treats it as fatal.  See relocate/validate.sh.
define do_validate
	$(SAY) VALIDATE '$(1)'
	$(Q)env $(PKG_ENV) BUILD_ROOT='$(BUILD_ROOT)' GLIBC_FLOOR='$(GLIBC_FLOOR)' \
	  GCC_VERSION='$(GCC_VERSION)' MPI_PROVIDER='$(MPI_PROVIDER)' \
	  HDF5_PARALLEL='$(HDF5_PARALLEL)' SLIM_PROFILE='$(SLIM_PROFILE)' \
	  ISA_BASELINE='$(ISA_BASELINE)' ISA_REPORT='$(WORK)/relocate/isa-scan.json' \
	  bash relocate/validate.sh --full --stage '$(1)' '$(STACK)'
endef

#-------------------------------------------------------------------------------
## conda: step 1 -- bootstrap miniforge and create the env AS the stack prefix
conda: $(STAMPS)/conda.stamp
$(STAMPS)/conda.stamp: conda/bootstrap.sh $(wildcard conda/env/*.yml) | $(STAMPS)
	$(call run_hooks,pre-conda)
	$(SAY) CONDA '$(TARGET_PLATFORM) $(BLAS_PROVIDER) $(MPI_FAMILY)'
	$(Q)env $(PKG_ENV) \
	  CONDA_HOME='$(CONDA_HOME)' STACK='$(STACK)' \
	  TARGET_PLATFORM='$(TARGET_PLATFORM)' GLIBC_FLOOR='$(GLIBC_FLOOR)' \
	  GCC_VERSION='$(GCC_VERSION)' MPI_VERSION='$(MPI_VERSION)' \
	  MPI_PROVIDER='$(MPI_PROVIDER)' \
	  HDF5_VERSION='$(HDF5_VERSION)' HDF5_PARALLEL='$(HDF5_PARALLEL)' \
	  IGNORE_LOCK='$(IGNORE_LOCK)' CONDA_RECREATE='$(CONDA_RECREATE)' \
	  bash conda/bootstrap.sh
	$(call run_hooks,post-conda)
	$(Q)touch $@

#-------------------------------------------------------------------------------
## build: step 2 -- build the source packages into the same prefix
build: $(STAMPS)/build.stamp
$(STAMPS)/build.stamp: $(STAMPS)/prebuild.stamp \
                       $(foreach p,$(BUILD_PKGS),$(STAMPS)/$(p).stamp) | $(STAMPS)
	$(call run_hooks,post-build)
	$(Q)touch $@

#-------------------------------------------------------------------------------
## wrappers: generate the build-time compiler wrappers that pin the ISA baseline
wrappers: $(STAMPS)/wrappers.stamp
$(STAMPS)/wrappers.stamp: $(STAMPS)/conda.stamp \
                          wrappers/generate.sh wrappers/selftest.sh | $(STAMPS)
	$(SAY) WRAPPERS '$(ISA_BASELINE)'
	$(Q)env $(PKG_ENV) WRAPPER_ON_NATIVE='$(WRAPPER_ON_NATIVE)' \
	  bash wrappers/generate.sh
# The self-test runs here, in the same recipe that generates them, rather than
# as a separate phony prerequisite of the build.  A phony gate would make
# prebuild.stamp perpetually out of date and rebuild every package; running it
# at generation time covers the only moment the answer can change.
	$(SAY) WRAPCHECK '$(ISA_BASELINE)'
	$(Q)env $(PKG_ENV) bash wrappers/selftest.sh
	$(Q)touch $@

## wrappers-check: prove the wrappers cap the ISA, by scanning what they emit
# Always re-runs: it is a gate, and it is seconds, not minutes.
wrappers-check: $(STAMPS)/wrappers.stamp wrappers/selftest.sh
	$(SAY) WRAPCHECK '$(ISA_BASELINE)'
	$(Q)env $(PKG_ENV) bash wrappers/selftest.sh

#-------------------------------------------------------------------------------
# pre-build runs once, before any package -- hence its own stamp rather than
# a hook on build.stamp, which runs after the packages.
#
# Source builds sit downstream of the wrappers, so no package can be compiled
# before the injection has been generated and proven.  A wrapper that silently
# stopped injecting would produce a stack that is wrong in the one way this
# project exists to prevent, and would look entirely normal doing it.
$(STAMPS)/prebuild.stamp: $(STAMPS)/wrappers.stamp | $(STAMPS)
	$(call run_hooks,pre-build)
	$(Q)touch $@
$(foreach p,$(PKGS),$(eval $(STAMPS)/$(p).stamp: $(STAMPS)/prebuild.stamp))

#-------------------------------------------------------------------------------
## test: build and run the smoke example in place -- always re-runs
test: $(STAMPS)/build.stamp
	$(call do_test,in place)

# step 3: in place, before anything is rewritten
$(STAMPS)/test-built.stamp: $(STAMPS)/build.stamp test/run.sh | $(STAMPS)
	$(call do_test,in place)
	$(Q)touch $@

#-------------------------------------------------------------------------------
## relocate: step 4 -- patchelf to $ORIGIN-relative rpaths, rewrite embedded paths
relocate: $(STAMPS)/relocate.stamp
$(STAMPS)/relocate.stamp: $(STAMPS)/test-built.stamp \
                          relocate/patchelf.sh relocate/fixup-text.sh | $(STAMPS)
	$(call run_hooks,pre-relocate)
	$(SAY) PATCHELF '$(RPATH_MODE)'
	$(Q)env $(PKG_ENV) bash relocate/patchelf.sh
	$(SAY) FIXUP 'embedded paths'
	$(Q)env $(PKG_ENV) BUILD_ROOT='$(BUILD_ROOT)' bash relocate/fixup-text.sh
# The ISA scan needs objdump, which prune.list removes along with the rest of
# binutils -- so it runs here, while the toolchain is still in the tree, and
# writes a report both validate stages read.  Same constraint that forces slim
# before prune; see A17.
	$(SAY) ISA-SCAN '$(ISA_BASELINE)'
	$(Q)"$(CONDA_HOME)/bin/python" relocate/isa-scan.py --root '$(STACK)' \
	  --out '$(WORK)/relocate/isa-scan.json' --jobs '$(NPROC)'
	$(call run_hooks,post-relocate)
	$(Q)touch $@

#-------------------------------------------------------------------------------
## validate: the gate -- no unexpected host dependencies, C++ runtime in-tree
validate: $(STAMPS)/relocate.stamp relocate/validate.sh
	$(call do_validate,relocated)

# the gate, immediately after relocation
$(STAMPS)/validate-relocated.stamp: $(STAMPS)/relocate.stamp relocate/validate.sh | $(STAMPS)
	$(call do_validate,relocated)
	$(Q)touch $@

# step 5: in place again, proving relocation did not break the build tree
$(STAMPS)/test-relocated.stamp: $(STAMPS)/validate-relocated.stamp test/run.sh | $(STAMPS)
	$(call do_test,in place / post-relocate)
	$(Q)touch $@

#-------------------------------------------------------------------------------
## slim: step 6 -- prune build-only conda packages, then trim files
slim: $(STAMPS)/slim.stamp
$(STAMPS)/slim.stamp: $(STAMPS)/test-relocated.stamp \
                      relocate/prune.sh relocate/slim.sh conda/prune.list | $(STAMPS)
	$(call run_hooks,pre-slim)
# slim BEFORE prune, which reverses the plan's order for a concrete reason:
# 'strip' is provided only by binutils_impl_*, which prune.list removes, and
# the miniforge base has no strip either.  Pruning first would silently turn
# stripping into a no-op.  See the header of relocate/slim.sh.
	$(SAY) SLIM '$(SLIM_PROFILE)'
	$(Q)env $(PKG_ENV) SLIM_PROFILE='$(SLIM_PROFILE)' bash relocate/slim.sh
	$(SAY) PRUNE 'conda/prune.list'
	$(Q)env $(PKG_ENV) SHIP_PYTHON='$(SHIP_PYTHON)' CONDA_HOME='$(CONDA_HOME)' \
	  bash relocate/prune.sh
	$(call run_hooks,post-slim)
	$(Q)touch $@

# the gate again, after pruning -- this is the one that catches a prune that
# took libstdc++.so.6 or libgcc_s.so.1 with it
$(STAMPS)/validate-slimmed.stamp: $(STAMPS)/slim.stamp relocate/validate.sh | $(STAMPS)
	$(call do_validate,final)
	$(Q)touch $@

#-------------------------------------------------------------------------------
## dist: step 7a -- reproducible tarball of the pruned, slimmed, validated tree
dist: $(STAMPS)/validate-slimmed.stamp | $(DIST_DIR)
	$(call run_hooks,pre-dist)
	$(SAY) TAR '$(notdir $(TARBALL))'
	$(Q)tar --sort=name --owner=0 --group=0 --numeric-owner \
	  --mtime="@$${SOURCE_DATE_EPOCH:-0}" \
	  -czf '$(TARBALL)' -C '$(BUILD_ROOT)' stack
	$(call run_hooks,post-dist)

## distcheck: step 7b -- untar at a different depth and prove it still works
distcheck: dist
	$(SAY) CHECK 'relocating to a different path depth'
	$(Q)env $(PKG_ENV) TARBALL='$(TARBALL)' BUILD_ROOT='$(BUILD_ROOT)' \
	  SMOKE_RANKS='$(SMOKE_RANKS)' GLIBC_FLOOR='$(GLIBC_FLOOR)' \
	  ISA_BASELINE='$(ISA_BASELINE)' ISA_REPORT='$(WORK)/relocate/isa-scan.json' \
	  bash test/distcheck.sh

#-------------------------------------------------------------------------------
## conda-lock: regenerate the checked-in explicit lock files
conda-lock:
	$(SAY) LOCK 'conda/lock'
	$(Q)env $(PKG_ENV) CONDA_HOME='$(CONDA_HOME)' \
	  HDF5_PARALLEL='$(HDF5_PARALLEL)' bash conda/lock.sh

## shell: an interactive shell with $(STACK)/bin on PATH
# Deliberately minimal.  $(STACK)/activate.sh, installed by relocate, is the
# real entry point; this exists for the stages before it.
shell: $(STAMPS)/conda.stamp
	$(SAY) SHELL '$(STACK)'
	$(Q)env $(PKG_ENV) PATH='$(STACK)/bin':"$$PATH" bash -i

## image-shell: pull the published image for this config and shell into it
# The remote counterpart of 'shell': no local build root needed.  Names the tag
# the same way CI did (STAGE=devel by default), pulls it, and drops in with the
# stack on PATH.  STAGE=builder for the toolchain-only image; STAGE, TARGET_PLATFORM,
# BLAS_PROVIDER, MPI_FAMILY, ... = ... to select a different published config.
image-shell:
	$(Q)STAGE='$(STAGE)' TARGET_PLATFORM='$(TARGET_PLATFORM)' \
	  BLAS_PROVIDER='$(BLAS_PROVIDER)' MPI_FAMILY='$(MPI_FAMILY)' \
	  HDF5_PARALLEL='$(HDF5_PARALLEL)' GLIBC_FLOOR='$(GLIBC_FLOOR)' \
	  GCC_VERSION='$(GCC_VERSION)' PROFILE='$(PROFILE)' \
	  bash docker/pull-shell.sh

## print-config: show the resolved knobs and paths
print-config:
	@printf '%-16s %s\n' \
	  BUILD_ROOT '$(BUILD_ROOT)' STACK '$(STACK)' PROFILE '$(PROFILE)' \
	  PETSC_VERSION '$(PETSC_VERSION)' LIBMESH_VERSION '$(LIBMESH_VERSION)' \
	  TRILINOS_VERSION '$(TRILINOS_VERSION)' TRILINOS_KOKKOS '$(TRILINOS_KOKKOS)' \
	  TARGET_PLATFORM '$(TARGET_PLATFORM)' GLIBC_FLOOR '$(GLIBC_FLOOR)' \
	  GCC_VERSION '$(GCC_VERSION)' BLAS_PROVIDER '$(BLAS_PROVIDER)' \
	  MPI_FAMILY '$(MPI_FAMILY)' MPI_PROVIDER '$(MPI_PROVIDER)' \
	  MPI_VERSION '$(MPI_VERSION)' ISA_BASELINE '$(ISA_BASELINE)' \
	  HDF5_VERSION '$(HDF5_VERSION)' HDF5_PARALLEL '$(HDF5_PARALLEL)' \
	  RPATH_MODE '$(RPATH_MODE)' \
	  USE_WRAPPERS '$(USE_WRAPPERS)' WRAPPER_ON_NATIVE '$(WRAPPER_ON_NATIVE)' \
	  SLIM_PROFILE '$(SLIM_PROFILE)' SHIP_PYTHON '$(SHIP_PYTHON)' \
	  SMOKE_RANKS '$(SMOKE_RANKS)' NPROC '$(NPROC)' MAKE_J_L '$(MAKE_J_L)' \
	  PACKAGES '$(BUILD_PKGS)' 'PACKAGES (opt)' '$(OPT_PKGS)' \
	  'PACKAGES (git)' '$(or $(strip $(foreach p,$(PKGS),$(if $(filter git,$(PKG_SOURCE_$(p))),$(p)@$(PKG_GIT_REF_$(p))))),none)' \
	  TARBALL '$(TARBALL)'

## clean: remove build stamps and logs, keep the conda env and caches
clean:
	$(Q)rm -rf '$(STAMPS)' '$(LOGS)'

## distclean: remove the entire build root
distclean:
	$(Q)rm -rf '$(BUILD_ROOT)'

## help: list the available targets
help:
	@echo 'Targets:'
	@grep -hE '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /' | sort
	@echo
	@echo "Run 'make print-config' to see the resolved settings."
