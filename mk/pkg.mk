# mk/pkg.mk -- the generic per-package build rule.
#
# Successor to the old rules/Make.pkg_deps, which needed three near-identical
# pattern rules because packages installed into <pkg>/<version>-<compiler-id>/
# directories.  With a single merged prefix there is exactly one rule.
#
# Dependencies are expressed as stamp prerequisites, so -- unlike the old
# .NOTPARALLEL: build -- independent packages can build concurrently.

define PKG_RULE
$(STAMPS)/$(1).stamp: $$(foreach d,$$(PKG_DEPS_$(1)),$(STAMPS)/$$(d).stamp) $$(PKG_DIR_$(1))build.sh | $(STAMPS) $(LOGS)
	$$(SAY) BUILD '$(1)-$$(PKG_VERSION_$(1))'
	$$(Q)env $$(PKG_ENV) \
	  PKG_NAME='$(1)' \
	  PKG_VERSION='$$(PKG_VERSION_$(1))' \
	  PKG_URL='$$(PKG_URL_$(1))' \
	  PKG_DIR='$$(PKG_DIR_$(1))' \
	  bash '$$(PKG_DIR_$(1))build.sh' > '$(LOGS)/$(1).log' 2>&1 \
	  || { echo "--- $(1) failed; tail of $(LOGS)/$(1).log ---" >&2; \
	       tail -40 '$(LOGS)/$(1).log' >&2; exit 1; }
	$$(Q)touch $$@

# per-package convenience target
.PHONY: $(1)
$(1): $(STAMPS)/$(1).stamp
endef
