# Smoke example -- the fixed contract test/run.sh builds against.
#
#   make all      build, and install the binary INTO the stack
#   make run      run it serially
#
# Installing into the stack rather than leaving the binary beside the source is
# what makes the relocated test meaningful: the binary travels inside the
# tarball, so after unpacking somewhere else there is a genuinely prebuilt
# executable to run.  A binary rebuilt against the relocated tree would prove
# much less -- and cannot be built at all in the verify image, which has no
# compiler.
#
# Object files go to BUILDDIR, never beside the source: docker/compose.yaml
# mounts this directory read-only into the verify service.

STACK    ?= $(error STACK must be set)
BUILDDIR ?= $(WORK)/smoke-build
SMOKE_BIN = $(STACK)/libexec/smoke

MPICC    ?= $(STACK)/bin/mpicc
CFLAGS   ?= -O2 -g -Wall

# mpicc already adds -L/-rpath for MPI's own libdir, which happens to be the
# same directory everything else lives in -- but relying on that would make the
# link depend on an MPI implementation detail.  Say it outright.  The absolute
# rpath is correct here and deliberate: relocate/patchelf.sh rewrites every
# rpath in the tree to $ORIGIN-relative afterwards.
#
# -rpath-link is separate from -rpath and is NOT redundant with it.  Linking
# '-lpetsc' makes ld resolve libpetsc.so's own DT_NEEDED entries (libHYPRE,
# libopenblas, ...), and ld does not use -rpath to find those -- only
# -rpath-link.  Measured: with -L and -rpath alone the link fails on
# 'undefined reference to HYPRE_AMSSetDimension' and 'dstev_', while
# 'ldd libpetsc.so' reports zero unresolved libraries.  The library is fine;
# the linker simply was not told where to look.  -rpath-link is link-time only
# and leaves nothing in the binary, so it cannot affect relocation.
LDFLAGS  += -L$(STACK)/lib -Wl,-rpath,$(STACK)/lib -Wl,-rpath-link,$(STACK)/lib

# Feature detection, so the example can grow as packages land without the
# contract changing.  Each block is additive.
ifneq ($(wildcard $(PETSC_DIR)/include/petscvec.h),)
  CFLAGS  += -DSMOKE_HAVE_PETSC -I$(PETSC_DIR)/include
  LDLIBS  += -lpetsc
endif

# --- libMesh's introduction_ex4 --------------------------------------------
#
# The plan's endpoint for this harness, and a much stronger test than smoke.c:
# a real FEM solve, in 1D/2D/3D, exercising libMesh, PETSc, HDF5 and MPI
# together.
#
# libMesh installs the example SOURCES and a Makefile but no binary, so the
# binary has to be built here and installed into $STACK/libexec -- the same
# trick smoke.c uses, and for the same reason: that is what makes it travel
# inside the tarball and gives distcheck a genuinely prebuilt executable to run
# after unpacking somewhere else.
#
# Built with libmesh-config rather than with the installed example Makefile.
# That Makefile drives libtool and compiles in place, which would leave objects
# inside $STACK; libmesh-config is libMesh's own documented contract for
# building against an installation, and it is what a customer would use.
LIBMESH_CONFIG := $(wildcard $(LIBMESH_DIR)/bin/libmesh-config)
EX4_DIR        := $(LIBMESH_DIR)/examples/introduction/ex4
EX4_SRC        := $(wildcard $(EX4_DIR)/*.C)
EX4_BIN         = $(STACK)/libexec/introduction_ex4
MPICXX         ?= $(STACK)/bin/mpicxx

.PHONY: all run clean
all: $(SMOKE_BIN)

ifneq ($(LIBMESH_CONFIG),)
ifneq ($(EX4_SRC),)
all: $(EX4_BIN)

# Backticks rather than $(shell ...) so the query happens when the recipe runs,
# not when the makefile is read.
# libmesh-config emits -L and -rpath but not -rpath-link, and ld needs the
# latter to resolve libmesh_opt.so's own DT_NEEDED entries (libnetcdf, libpetsc,
# ...).  Same reason as above; -L does not participate in that search at all.
$(EX4_BIN): $(EX4_SRC) | $(BUILDDIR)
	$(MPICXX) `METHOD=opt $(LIBMESH_CONFIG) --cppflags --cxxflags --include` \
	  -o $(BUILDDIR)/introduction_ex4 $(EX4_SRC) \
	  -Wl,-rpath-link,$(STACK)/lib \
	  `METHOD=opt $(LIBMESH_CONFIG) --libs`
	mkdir -p $(dir $@)
	cp $(BUILDDIR)/introduction_ex4 $@
endif
endif

$(SMOKE_BIN): smoke.c | $(BUILDDIR)
	$(MPICC) $(CFLAGS) -o $(BUILDDIR)/smoke smoke.c $(LDFLAGS) $(LDLIBS)
	mkdir -p $(dir $@)
	cp $(BUILDDIR)/smoke $@

$(BUILDDIR):
	mkdir -p $@

run: $(SMOKE_BIN)
	$(SMOKE_BIN)

clean:
	rm -rf $(BUILDDIR) $(SMOKE_BIN) $(EX4_BIN)
