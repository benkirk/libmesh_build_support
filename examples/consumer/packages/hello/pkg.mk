# hello -- a customer package that builds a shared library ON TOP of libMesh.
#
# This is one half of the worked "consumer" example (see examples/consumer/).
# It is an ordinary package: exactly the pkg.mk + build.sh pair a customer
# writes, discovered through SITE_DIRS like anything in site/.  The only thing
# that makes it a "consumer" package rather than a "site" one is WHERE it lives
# -- in the customer's own repository, with this repo vendored as a submodule --
# and nothing here has to know that.
#
# ':=' throughout, never '?=': declare_pkg clears these names to
# defined-but-empty after each package, so a '?=' in any package included after
# the first silently does nothing.  See mk/common.mk and docs/EXTENDING.md.

PKG_NAME    := hello
PKG_VERSION := 1.0.0

# No upstream release: a package that generates or vendors its own sources
# simply never calls download_src.  A customer's first package is usually
# exactly this -- their own code, not a tarball.
PKG_URL     :=

# Built after libMesh, because it compiles against it.  MPI, BLAS and HDF5 need
# no entry -- the conda env is an implicit dependency of every package.
PKG_DEPS    := libmesh

# In the graph 'make build' walks.  'optional' would give it a target of its
# own ('make hello') without putting it in the default stack.
PKG_STAGE   := build

$(eval $(call declare_pkg))
