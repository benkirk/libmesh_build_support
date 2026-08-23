# goodbye -- a customer application that depends on the customer's OWN 'hello'
# package (which in turn depends on libMesh).
#
# This is the point of the two-package example: PKG_DEPS names 'hello', a
# sibling customer package, not one of ours.  The framework orders the whole
# chain -- libmesh -> hello -> goodbye -- from these declarations alone, exactly
# as it orders libmesh -> petsc internally, so a customer's dependency graph is
# a first-class citizen of the build with no special handling.
#
# ':=' throughout, never '?=' (declare_pkg clears these afterward).

PKG_NAME    := goodbye
PKG_VERSION := 1.0.0
PKG_URL     :=

# Depends on a CUSTOMER package, not one of ours.  hello already pulls in
# libMesh, so goodbye reaches the whole stack transitively.
PKG_DEPS    := hello

PKG_STAGE   := build

$(eval $(call declare_pkg))
