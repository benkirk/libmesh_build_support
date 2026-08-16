! gust_hello_f03.f90 -- package B, the Fortran 2003 front-end.
!
! Third language, same claim: this program runs a parallel FEM problem and
! never names MPI, PETSc or libMesh.  It uses one module -- gust_core, shipped
! by package A -- and the two intrinsic ones.
!
! The Fortran 2003 features here are not decoration; each is the thing that
! makes a particular part of the C boundary crossable at all:
!
!   ISO_C_BINDING       interoperable kinds, so integer(c_int) IS a C int
!   BIND(C) type        gust_probe_t laid out exactly as the C struct
!   C_NULL_PTR          what a Fortran main passes for argc/argv, having none
!   C_F_POINTER         turning the const char* from gust_core_version() into
!                       something Fortran can read
!   ISO_FORTRAN_ENV     output_unit / error_unit rather than unit numbers
!
! Before Fortran 2003 the honest options were a hand-written C shim per
! function and a prayer about struct padding.  The whole reason package A's
! ABI is C rather than C++ is that this file can then exist without one line
! of glue on either side.

program gust_hello_f03

  use, intrinsic :: iso_c_binding,  only : c_int, c_char, c_ptr, c_null_ptr, &
                                           c_null_char, c_f_pointer
  use, intrinsic :: iso_fortran_env, only : output_unit, error_unit
  use :: gust_core

  implicit none

  integer(c_int), parameter :: refinements = 2

  type(gust_probe_t) :: probe
  integer(c_int)     :: rc, rank, ranks
  integer            :: side, want_elements, want_dofs
  character(len=gust_backend_len) :: backend
  character(len=64)  :: version

  ! C_NULL_PTR for both: a Fortran main program has no argc/argv, and package
  ! A documents NULL/NULL as "no command line".
  rc = gust_core_init (c_null_ptr, c_null_ptr)
  if (rc /= 0) then
     write (error_unit, '(a)') 'gust-hello-f03: could not bring up the stack'
     stop 1
  end if

  rank  = gust_core_rank ()
  ranks = gust_core_ranks ()

  ! One line per rank, as the C and C++ front-ends print, so the harness sees
  ! the same shape from all three and N processes that each believe they are
  ! rank 0 of 1 cannot pass quietly.
  write (output_unit, '(a,i0,a,i0)') 'gust-hello-f03: rank ', rank, '/', ranks
  flush (output_unit)

  rc = gust_core_probe (refinements, probe)
  if (rc /= 0) then
     write (error_unit, '(a,i0)') 'gust-hello-f03: probe failed on rank ', rank
     stop 1
  end if

  ! The same arithmetic the C front-end checks, restated here rather than
  ! trusted: if the BIND(C) derived type did not match the C struct byte for
  ! byte, these fields would read as garbage or as each other, and a test that
  ! only printed them would sail straight past it.
  side          = 4 * (2 ** refinements)
  want_elements = side * side
  want_dofs     = (side + 1) * (side + 1)

  if (probe%elements /= want_elements .or. probe%dofs /= want_dofs) then
     write (error_unit, '(a,i0,a,i0,a,i0,a,i0,a)')                     &
          'gust-hello-f03: struct mismatch -- elements ', probe%elements, &
          ' (want ', want_elements, '), dofs ', probe%dofs,              &
          ' (want ', want_dofs, ')'
     stop 1
  end if

  if (probe%rank /= rank .or. probe%ranks /= ranks) then
     write (error_unit, '(a)') 'gust-hello-f03: struct rank fields disagree'
     stop 1
  end if

  backend = c_array_to_string (probe%backend, gust_backend_len)
  version = c_ptr_to_string (gust_core_version (), len (version))

  if (rank == 0) then
     write (output_unit, '(a)')                                          &
          'gust-hello-f03: hello from Gust App (Fortran 2003)'
     write (output_unit, '(4a)')                                         &
          'gust-hello-f03: gust-core ', trim (version), ', ', trim (backend)
     write (output_unit, '(a,i0,a,i0,a,i0)')                             &
          'gust-hello-f03: solved on ', ranks, ' rank(s): ',             &
          probe%elements, ' elements, ', probe%dofs
     flush (output_unit)
  end if

  call gust_core_finalize ()

contains

  ! The NUL scan the interface module deliberately does not provide.  See the
  ! comment at the top of gust_core_mod.f90: keeping it out of the module is
  ! what stops every C and C++ consumer of package A from acquiring a
  ! libgfortran dependency to reach it.
  pure function c_array_to_string (chars, n) result (s)
    character(kind=c_char), intent(in) :: chars(*)
    integer,                intent(in) :: n
    character(len=n) :: s
    integer :: i
    s = ''
    do i = 1, n
       if (chars(i) == c_null_char) exit
       s(i:i) = chars(i)
    end do
  end function c_array_to_string

  ! C_F_POINTER over a const char* whose length Fortran cannot know up front:
  ! map a generous fixed window onto it, then stop at the first NUL.
  function c_ptr_to_string (p, n) result (s)
    type(c_ptr), intent(in) :: p
    integer,     intent(in) :: n
    character(len=n) :: s
    character(kind=c_char), pointer :: buf(:)
    s = ''
    call c_f_pointer (p, buf, [n])
    if (.not. associated (buf)) return
    s = c_array_to_string (buf, n)
  end function c_ptr_to_string

end program gust_hello_f03
