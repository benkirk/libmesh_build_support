! gust_core_mod.f90 -- the Fortran 2003 face of package A's C API.
!
! Package A ships one ABI and three bindings onto it.  gust_core.h serves C and
! C++ directly; this module serves Fortran, and it does so without a single
! line of glue code on either side -- ISO_C_BINDING describes the existing C
! entry points exactly as they already are.
!
! DELIBERATELY INTERFACE-ONLY.  There is no `contains` block, so the module
! defines no procedure a caller has to link against, and the object file from
! compiling it is discarded -- only the .mod is installed.  Two things follow,
! both of them the reason for the choice:
!
!   - libgustcore.so acquires no Fortran runtime dependency.  If the module
!     carried even one helper procedure, every C and C++ consumer of package A
!     would start pulling in libgfortran to get it.
!   - there is nothing to keep in sync.  A helper here could drift from the C
!     implementation; an interface block cannot -- if it disagrees with the
!     library, the link fails.
!
! "No procedure" is not the same as "no symbols", which is worth stating
! because it is measurable and the obvious check gets it wrong: gfortran emits
! __vtab_/__copy_/__def_init_ symbols for the derived type below whether or not
! anything ever uses them polymorphically.  Those are type support, not code
! anyone calls.  The property that actually matters is checked the only way
! that cannot be fooled -- customer/test/abi-check.sh links gust_hello_f03
! WITHOUT this module's object file, and a link that succeeds is the proof.
!
! The cost is that a caller converting `backend` to a Fortran string writes the
! NUL scan itself.  That is five lines, once, in the caller -- see
! gust_hello_f03.f90 -- and it buys the two properties above.
!
! CAVEAT, on shipping the .mod: a Fortran module file is gfortran-version
! specific, so the installed gust_core.mod is only usable by the compiler that
! wrote it.  That is fine here and worth understanding why -- the artifact
! ships no compiler at all (conda/prune.list drops gcc_impl and the sysroot),
! so the supported way to build against this stack is inside the template,
! before the prune, where the module and the compiler that made it are the same
! pair.  A customer compiling against the unpacked tarball with their own
! gfortran should use this source file, not the installed .mod.

module gust_core

  use, intrinsic :: iso_c_binding, only : c_int, c_char, c_ptr

  implicit none
  private

  public :: gust_probe_t, gust_backend_len
  public :: gust_core_init, gust_core_rank, gust_core_ranks
  public :: gust_core_probe, gust_core_finalize, gust_core_version

  ! Must equal the C struct's char backend[64].  A mismatch here is not a
  ! compile error in either language -- it is a silently wrong struct layout --
  ! which is why the ABI check in customer/test/ exists.
  integer, parameter :: gust_backend_len = 64

  ! BIND(C) is what makes this interoperable rather than merely similar: the
  ! compiler is required to lay it out exactly as the companion C processor
  ! lays out the matching struct, with no reordering and no Fortran padding
  ! rules of its own.
  type, bind(c) :: gust_probe_t
     integer(c_int)         :: ranks
     integer(c_int)         :: rank
     integer(c_int)         :: elements
     integer(c_int)         :: dofs
     character(kind=c_char) :: backend(gust_backend_len)
  end type gust_probe_t

  interface

     ! argc/argv as C_PTR BY VALUE, which is what int* and char*** are at the
     ! ABI level.  A Fortran main has neither, so it passes C_NULL_PTR for both
     ! and gust_core_init substitutes a synthetic command line -- see the note
     ! on the C declaration in gust_core.h.
     integer(c_int) function gust_core_init (argc, argv) bind(c, name='gust_core_init')
       import :: c_int, c_ptr
       type(c_ptr), value :: argc
       type(c_ptr), value :: argv
     end function gust_core_init

     integer(c_int) function gust_core_rank () bind(c, name='gust_core_rank')
       import :: c_int
     end function gust_core_rank

     integer(c_int) function gust_core_ranks () bind(c, name='gust_core_ranks')
       import :: c_int
     end function gust_core_ranks

     ! `refinements` by value (C takes an int), `probe` by reference (C takes a
     ! pointer).  Fortran's default is pass-by-reference, so the absence of
     ! VALUE on the second argument is what makes it a gust_probe_t*.
     integer(c_int) function gust_core_probe (refinements, probe) bind(c, name='gust_core_probe')
       import :: c_int, gust_probe_t
       integer(c_int), value            :: refinements
       type(gust_probe_t), intent(out)  :: probe
     end function gust_core_probe

     subroutine gust_core_finalize () bind(c, name='gust_core_finalize')
     end subroutine gust_core_finalize

     ! Returns const char* -- a C_PTR to be walked with C_F_POINTER, since
     ! Fortran cannot know the length in advance.
     type(c_ptr) function gust_core_version () bind(c, name='gust_core_version')
       import :: c_ptr
     end function gust_core_version

  end interface

end module gust_core
