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
LDFLAGS  += -L$(STACK)/lib -Wl,-rpath,$(STACK)/lib

# Feature detection, so the example can grow as packages land without the
# contract changing.  Each block is additive.
ifneq ($(wildcard $(PETSC_DIR)/include/petscvec.h),)
  CFLAGS  += -DSMOKE_HAVE_PETSC -I$(PETSC_DIR)/include
  LDLIBS  += -lpetsc
endif

.PHONY: all run clean
all: $(SMOKE_BIN)

$(SMOKE_BIN): smoke.c | $(BUILDDIR)
	$(MPICC) $(CFLAGS) -o $(BUILDDIR)/smoke smoke.c $(LDFLAGS) $(LDLIBS)
	mkdir -p $(dir $@)
	cp $(BUILDDIR)/smoke $@

$(BUILDDIR):
	mkdir -p $@

run: $(SMOKE_BIN)
	$(SMOKE_BIN)

clean:
	rm -rf $(BUILDDIR) $(SMOKE_BIN)
