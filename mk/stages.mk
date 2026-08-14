# mk/stages.mk -- the stage targets and their ordering.
# Mirrors the numbered steps in docs/RELOCATABLE-STACK-PLAN.md:
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

.PHONY: all conda build test relocate validate slim dist distcheck \
        help shell clean distclean conda-lock print-config

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

# pre-build runs once, before any package -- hence its own stamp rather than
# a hook on build.stamp, which runs after the packages.
$(STAMPS)/prebuild.stamp: $(STAMPS)/conda.stamp | $(STAMPS)
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
	  bash test/distcheck.sh

#-------------------------------------------------------------------------------
## conda-lock: regenerate the checked-in explicit lock files
conda-lock:
	$(SAY) LOCK 'conda/lock'
	$(Q)env $(PKG_ENV) CONDA_HOME='$(CONDA_HOME)' \
	  HDF5_PARALLEL='$(HDF5_PARALLEL)' bash conda/lock.sh

## shell: an interactive shell with $(STACK)/bin on PATH
# Deliberately minimal.  Once S4 lands, $(STACK)/activate.sh is the real entry
# point and this becomes a thin wrapper around it.
shell: $(STAMPS)/conda.stamp
	$(SAY) SHELL '$(STACK)'
	$(Q)env $(PKG_ENV) PATH='$(STACK)/bin':"$$PATH" bash -i

## print-config: show the resolved knobs and paths
print-config:
	@printf '%-16s %s\n' \
	  BUILD_ROOT '$(BUILD_ROOT)' STACK '$(STACK)' PROFILE '$(PROFILE)' \
	  TARGET_PLATFORM '$(TARGET_PLATFORM)' GLIBC_FLOOR '$(GLIBC_FLOOR)' \
	  GCC_VERSION '$(GCC_VERSION)' BLAS_PROVIDER '$(BLAS_PROVIDER)' \
	  MPI_FAMILY '$(MPI_FAMILY)' MPI_PROVIDER '$(MPI_PROVIDER)' \
	  MPI_VERSION '$(MPI_VERSION)' ISA_BASELINE '$(ISA_BASELINE)' \
	  HDF5_VERSION '$(HDF5_VERSION)' HDF5_PARALLEL '$(HDF5_PARALLEL)' \
	  RPATH_MODE '$(RPATH_MODE)' \
	  SLIM_PROFILE '$(SLIM_PROFILE)' SHIP_PYTHON '$(SHIP_PYTHON)' \
	  SMOKE_RANKS '$(SMOKE_RANKS)' NPROC '$(NPROC)' MAKE_J_L '$(MAKE_J_L)' \
	  PACKAGES '$(BUILD_PKGS)' 'PACKAGES (opt)' '$(OPT_PKGS)' \
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
