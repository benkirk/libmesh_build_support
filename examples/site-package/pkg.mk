# A worked site package.  Copy the whole directory into site/ to use it:
#
#     cp -r examples/site-package site/site-demo
#     make build
#
# site/ is gitignored and auto-discovered, so nothing tracked in this repo has
# to change for a customer to add packages.  This example lives under examples/
# rather than site/ precisely so it CAN be tracked -- and so it is exercised
# rather than merely described.  See docs/EXTENDING.md.

PKG_NAME    := site-demo
PKG_VERSION := 1.0.0

# No tarball.  PKG_URL is optional: a package that generates or vendors its own
# sources simply never calls download_src.  Shown here because a customer's
# first package is often exactly this -- local code, not an upstream release.
PKG_URL     :=

# Build after PETSc, because this links against it.  MPI, BLAS and HDF5 need no
# entry: the conda env is an implicit dependency of every package.
PKG_DEPS    := petsc

# 'build' puts it in the graph 'make build' walks.  'optional' would give it a
# target of its own -- 'make site-demo' -- without making it part of the default
# stack.
PKG_STAGE   := build

$(eval $(call declare_pkg))
