# mk/stages.mk -- the stage targets and their ordering.
# Mirrors the seven steps in docs/RELOCATABLE-STACK-PLAN.md.

.PHONY: all conda build test relocate validate slim dist distcheck \
        help shell clean distclean conda-lock print-config

## all: run the whole workflow, conda through distcheck
all: dist

$(BUILD_ROOT) $(STACK) $(WORK) $(STAMPS) $(LOGS) $(SRC_CACHE) $(DIST_DIR):
	$(Q)mkdir -p $@

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
	  bash conda/bootstrap.sh
	$(call run_hooks,post-conda)
	$(Q)touch $@

#-------------------------------------------------------------------------------
## build: step 2 -- build the source packages into the same prefix
build: $(STAMPS)/build.stamp
$(STAMPS)/build.stamp: $(STAMPS)/conda.stamp $(foreach p,$(PKGS),$(STAMPS)/$(p).stamp) | $(STAMPS)
	$(call run_hooks,post-build)
	$(Q)touch $@

# Every package depends on the conda env existing first.
$(foreach p,$(PKGS),$(eval $(STAMPS)/$(p).stamp: $(STAMPS)/conda.stamp))

#-------------------------------------------------------------------------------
## test: steps 3 and 5 -- build and run the smoke example in place
test: $(STAMPS)/build.stamp
	$(SAY) TEST 'in place'
	$(Q)env $(PKG_ENV) SMOKE_RANKS='$(SMOKE_RANKS)' bash test/run.sh inplace

#-------------------------------------------------------------------------------
## relocate: step 4 -- patchelf to $ORIGIN-relative rpaths, rewrite embedded paths
relocate: $(STAMPS)/relocate.stamp
$(STAMPS)/relocate.stamp: $(STAMPS)/build.stamp relocate/patchelf.sh relocate/fixup-text.sh | $(STAMPS)
	$(call run_hooks,pre-relocate)
	$(SAY) PATCHELF '$(RPATH_MODE)'
	$(Q)env $(PKG_ENV) bash relocate/patchelf.sh
	$(SAY) FIXUP 'embedded paths'
	$(Q)env $(PKG_ENV) BUILD_ROOT='$(BUILD_ROOT)' bash relocate/fixup-text.sh
	$(call run_hooks,post-relocate)
	$(Q)touch $@

#-------------------------------------------------------------------------------
## validate: the gate -- no unexpected host dependencies, C++ runtime in-tree
validate: relocate/validate.sh
	$(SAY) VALIDATE '$(STACK)'
	$(Q)env $(PKG_ENV) BUILD_ROOT='$(BUILD_ROOT)' GLIBC_FLOOR='$(GLIBC_FLOOR)' \
	  bash relocate/validate.sh

#-------------------------------------------------------------------------------
## slim: step 6 -- prune build-only conda packages, then trim files
slim: $(STAMPS)/relocate.stamp
	$(call run_hooks,pre-slim)
	$(SAY) PRUNE 'conda/prune.list'
	$(Q)env $(PKG_ENV) SHIP_PYTHON='$(SHIP_PYTHON)' CONDA_HOME='$(CONDA_HOME)' \
	  bash relocate/prune.sh
	$(SAY) SLIM '$(SLIM_PROFILE)'
	$(Q)env $(PKG_ENV) SLIM_PROFILE='$(SLIM_PROFILE)' bash relocate/slim.sh
	$(call run_hooks,post-slim)

#-------------------------------------------------------------------------------
## dist: step 7a -- reproducible tarball
dist: $(STAMPS)/relocate.stamp | $(DIST_DIR)
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
	$(Q)env $(PKG_ENV) CONDA_HOME='$(CONDA_HOME)' bash conda/lock.sh

## print-config: show the resolved knobs and paths
print-config:
	@printf '%-16s %s\n' \
	  BUILD_ROOT '$(BUILD_ROOT)' STACK '$(STACK)' PROFILE '$(PROFILE)' \
	  TARGET_PLATFORM '$(TARGET_PLATFORM)' GLIBC_FLOOR '$(GLIBC_FLOOR)' \
	  GCC_VERSION '$(GCC_VERSION)' BLAS_PROVIDER '$(BLAS_PROVIDER)' \
	  MPI_FAMILY '$(MPI_FAMILY)' MPI_PROVIDER '$(MPI_PROVIDER)' \
	  MPI_VERSION '$(MPI_VERSION)' RPATH_MODE '$(RPATH_MODE)' \
	  SLIM_PROFILE '$(SLIM_PROFILE)' SHIP_PYTHON '$(SHIP_PYTHON)' \
	  SMOKE_RANKS '$(SMOKE_RANKS)' NPROC '$(NPROC)' \
	  PACKAGES '$(PKGS)' TARBALL '$(TARBALL)'

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
