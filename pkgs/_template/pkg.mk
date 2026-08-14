# Copy this directory to pkgs/<name>/ or site/<name>/ and edit.
# site/ is gitignored and auto-discovered, so customers add packages there
# without touching anything tracked in this repo.

PKG_NAME    := example
PKG_VERSION := 1.0.0
PKG_URL     := https://example.invalid/example-1.0.0.tar.gz

# Names of other packages that must be built first. The conda env is always
# an implicit dependency, so MPI/BLAS/HDF5 need not be listed.
PKG_DEPS    :=

$(eval $(call declare_pkg))
