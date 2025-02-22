!
! (C) Copyright 2019 UCAR
!
! This software is licensed under the terms of the Apache Licence Version 2.0
! which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.

module fv3jedi_geom_iter_mod

  use iso_c_binding
  use kinds
  use atlas_module, only: atlas_field
  use fv3jedi_geom_mod, only: fv3jedi_geom, getVerticalCoord
  use fv3jedi_constants_mod, only: constant

! oops
  use missing_values_mod

  implicit none

  private
  public :: fv3jedi_geom_iter
  public :: fv3jedi_geom_iter_registry
  public :: fv3jedi_geom_iter_setup, fv3jedi_geom_iter_clone, fv3jedi_geom_iter_equals
  public :: fv3jedi_geom_iter_current, fv3jedi_geom_iter_next
  public :: fv3jedi_geom_iter_orography
  public :: fv3jedi_geom_iter_nominal_surface_pressure

  type :: fv3jedi_geom_iter
    type(fv3jedi_geom), pointer :: geom => null() !< Geometry
    integer :: iindex = 1  !< index e.g. lat(iindex,jindex)
    integer :: jindex = 1  !<
    integer :: kindex = 1  !<
  end type fv3jedi_geom_iter

#define LISTED_TYPE fv3jedi_geom_iter

  !> Linked list interface - defines registry_t type
#include "oops/util/linkedList_i.f"

  !> Global registry
  type(registry_t) :: fv3jedi_geom_iter_registry

contains

  ! ------------------------------------------------------------------------------
  ! Public
  ! ------------------------------------------------------------------------------

  !> Linked list implementation
#include "oops/util/linkedList_c.f"

  ! ------------------------------------------------------------------------------
  !> Setup for the geometry iterator
  subroutine fv3jedi_geom_iter_setup(self, geom, iindex, jindex, kindex)

    ! Passed variables
    type(fv3jedi_geom_iter),     intent(inout) :: self !< Geometry iterator
    type(fv3jedi_geom), pointer, intent(   in) :: geom !< Geometry
    integer,                     intent(   in) :: iindex, jindex,kindex  !< Index

    ! Associate geometry
    self%geom => geom

    ! Define iindex/jindex/kindex for local tile
    self%iindex = iindex
    self%jindex = jindex
    self%kindex = kindex

  end subroutine fv3jedi_geom_iter_setup

  ! ------------------------------------------------------------------------------
  !> Clone for the geometry iterator
  subroutine fv3jedi_geom_iter_clone(self, other)

    ! Passed variables
    type(fv3jedi_geom_iter), intent(inout) :: self  !< Geometry iterator
    type(fv3jedi_geom_iter), intent(   in) :: other !< Other geometry iterator

    ! Associate geometry
    self%geom => other%geom

    ! Copy iindex/jindex
    self%iindex = other%iindex
    self%jindex = other%jindex
    self%kindex = other%kindex

  end subroutine fv3jedi_geom_iter_clone

  ! ------------------------------------------------------------------------------
  !> Check for the geometry iterator equality
  subroutine fv3jedi_geom_iter_equals(self, other, equals)

    ! Passed variables
    type(fv3jedi_geom_iter), intent( in) :: self   !< Geometry iterator
    type(fv3jedi_geom_iter), intent( in) :: other  !< Other geometry iterator
    integer,            intent(out) :: equals !< Equality flag

    ! Initialization
    equals = 0

    ! Check equality
    if (associated(self%geom, other%geom)) then
      select case(self%geom%iterator_dimension)
      case (2) ! 2-d iterator
        if ((self%iindex==other%iindex) .and. (self%jindex==other%jindex)) equals = 1
      case (3) ! 3-d iterator
        if ((self%iindex==other%iindex) .and. (self%jindex==other%jindex) .and. &
            (self%kindex==other%kindex) ) equals = 1
      case default
        call abor1_ftn('fv3jedi_geom_iter_equals: unknown geom%iterator_dimension')
      end select
    endif

  end subroutine fv3jedi_geom_iter_equals

  ! ------------------------------------------------------------------------------
  !> Get geometry iterator current lat/lon/vCoord
  subroutine fv3jedi_geom_iter_current(self, lon, lat, vCoord)

    ! Passed variables
    type(fv3jedi_geom_iter), intent( in) :: self !< Geometry iterator
    real(kind_real),    intent(out) :: lat  !< Latitude
    real(kind_real),    intent(out) :: lon  !< Longitude
    real(kind_real),    intent(out) :: vCoord  !< Vertical Coordinator

    real(kind_real)                           :: psurf
    real(kind_real), dimension(self%geom%npz) :: prs

    type(atlas_field) :: nsp_field
    real(kind=kind_real), pointer :: nsp_ptr(:,:)
    integer :: nsp_index
    logical :: has_nsp

    ! Get pointer to nominal_surface_pressure data
    ! Note: data in the atlas::FieldSet is stored as unstructured 1D array (owned points first,
    ! halo points second). To access the nominal_surface_pressure value, we'll compute the 1D index into the
    ! owned points corresponding to the current iterator. (Alternatively, we could reshape the
    ! array, but this would require an allocation.)
    has_nsp = self%geom%geometry_fields%has_field("nominal_surface_pressure")
    if (has_nsp) then
       nsp_field = self%geom%geometry_fields%field('nominal_surface_pressure')
       call nsp_field%data(nsp_ptr)
    endif

    ! Check iindex/jindex
    if (self%iindex == -1 .AND. self%jindex == -1) then
      ! special case of {-1,-1} means end of the grid
      lat = self%geom%grid_lat(self%geom%iec,self%geom%jec)
      lon = self%geom%grid_lon(self%geom%iec,self%geom%jec)
    elseif (self%iindex < self%geom%isc .OR. self%iindex > self%geom%iec .OR. &
            self%jindex < self%geom%jsc .OR. self%jindex > self%geom%jec) then
      ! outside of the grid
      call abor1_ftn('fv3jedi_geom_iter_current: iterator out of bounds')
    else
      ! inside of the grid
      lat = self%geom%grid_lat(self%iindex,self%jindex)
      lon = self%geom%grid_lon(self%iindex,self%jindex)
    endif

    !convert to degrees from radians
    lat = constant('rad2deg')*lat
    lon = constant('rad2deg')*lon

    ! check kindex
    select case(self%geom%iterator_dimension)
    case (2) ! 2-d iterator
!     vCoord = missing_value(0.0_kind_real)
      vCoord = -99999
    case (3) ! 3-d iterator
      if (has_nsp) then
        nsp_index = (self%iindex - self%geom%isc + 1) &
                    + (self%jindex - self%geom%jsc) * (self%geom%iec - self%geom%isc + 1)
        psurf = nsp_ptr(1, nsp_index)
      else
        psurf = 100000.0_kind_real
      endif
      call getVerticalCoord(self%geom, prs, self%geom%npz, psurf)
      if (self%kindex == -1) then
        ! special case of {-1} means end of the grid
        vCoord = prs(self%geom%kec)
      elseif (self%kindex == 0) then
        ! special case of the surface fields
        vCoord = prs(self%geom%kec)
      elseif (self%kindex < 0 .OR. self%kindex > self%geom%kec) then
        ! out of range
        call abor1_ftn('fv3jedi_geom_iter_current: depth iterator out of bounds')
      else
        ! inside of the 3D grid
        vCoord = prs(self%kindex)
      endif
    case default
      call abor1_ftn('fv3jedi_geom_iter_current: unknown geom%iterator_dimension')
    end select

  end subroutine fv3jedi_geom_iter_current

  ! ------------------------------------------------------------------------------
  !> Get geometry iterator current lat/lon
  subroutine fv3jedi_geom_iter_orography(self, oro)

    ! Passed variables
    type(fv3jedi_geom_iter), intent( in) :: self !< Geometry iterator
    real(kind_real),    intent(out) :: oro  !< Orography

    type(atlas_field) :: orog_field
    real(kind=kind_real), pointer :: orog_ptr(:,:)
    integer :: orog_index

    ! Get pointer to orography data
    ! Note: data in the atlas::FieldSet is stored as unstructured 1D array (owned points first,
    ! halo points second). To access the orography value, we'll compute the 1D index into the
    ! owned points corresponding to the current iterator. (Alternatively, we could reshape the
    ! array, but this would require an allocation.)
    orog_field = self%geom%geometry_fields%field('filtered_orography')
    call orog_field%data(orog_ptr)

    ! Check iindex/jindex
    if (self%iindex == -1 .AND. self%jindex == -1) then
      ! special case of {-1,-1} means end of the grid
      oro = orog_ptr(1, self%geom%ngrid)
    elseif (self%iindex < self%geom%isc .OR. self%iindex > self%geom%iec .OR. &
            self%jindex < self%geom%jsc .OR. self%jindex > self%geom%jec) then
      ! outside of the grid
      call abor1_ftn('fv3jedi_geom_iter_orography: iterator out of bounds')
    else
      ! inside of the grid
      orog_index = (self%iindex - self%geom%isc + 1) &
                   + (self%jindex - self%geom%jsc) * (self%geom%iec - self%geom%isc + 1)
      oro = orog_ptr(1, orog_index)
    endif

  end subroutine fv3jedi_geom_iter_orography

  ! ------------------------------------------------------------------------------
  !> Get geometry iterator current lat/lon
  subroutine fv3jedi_geom_iter_nominal_surface_pressure(self, nsp)

    ! Passed variables
    type(fv3jedi_geom_iter), intent( in) :: self !< Geometry iterator
    real(kind_real),    intent(out) :: nsp  !< Orography

    type(atlas_field) :: nsp_field
    real(kind=kind_real), pointer :: nsp_ptr(:,:)
    integer :: nsp_index

    ! Get pointer to nominal_surface_pressure data
    ! Note: data in the atlas::FieldSet is stored as unstructured 1D array (owned points first,
    ! halo points second). To access the nominal_surface_pressure value, we'll compute the 1D index into the
    ! owned points corresponding to the current iterator. (Alternatively, we could reshape the
    ! array, but this would require an allocation.)
    nsp_field = self%geom%geometry_fields%field('nominal_surface_pressure')
    call nsp_field%data(nsp_ptr)

    ! Check iindex/jindex
    if (self%iindex == -1 .AND. self%jindex == -1) then
      ! special case of {-1,-1} means end of the grid
      nsp = nsp_ptr(1, self%geom%ngrid)
    elseif (self%iindex < self%geom%isc .OR. self%iindex > self%geom%iec .OR. &
            self%jindex < self%geom%jsc .OR. self%jindex > self%geom%jec) then
      ! outside of the grid
      call abor1_ftn('fv3jedi_geom_iter_nominal_surface_pressure: iterator out of bounds')
    else
      ! inside of the grid
      nsp_index = (self%iindex - self%geom%isc + 1) &
                  + (self%jindex - self%geom%jsc) * (self%geom%iec - self%geom%isc + 1)
      nsp = nsp_ptr(1, nsp_index)
    endif

  end subroutine fv3jedi_geom_iter_nominal_surface_pressure

  ! ------------------------------------------------------------------------------
  !> Update geometry iterator to next point
  subroutine fv3jedi_geom_iter_next(self)

    ! Passed variables
    type(fv3jedi_geom_iter), intent(inout) :: self !< Geometry iterator
    integer :: iindex, jindex, kindex

    iindex = self%iindex
    jindex = self%jindex
    kindex = self%kindex

    select case(self%geom%iterator_dimension)
      case (2) ! 2-d iterator
        if (iindex.lt.self%geom%iec) then
          iindex = iindex + 1
        elseif (iindex.eq.self%geom%iec) then
          iindex = self%geom%isc
          jindex = jindex + 1
        end if

        if (jindex > self%geom%jec) then
          iindex=-1
          jindex=-1
        end if
        kindex=missing_value(0)
!       kindex=-999
      case (3) ! 3-d iterator
        if (iindex.lt.self%geom%iec) then
          iindex = iindex + 1
        elseif (iindex.eq.self%geom%iec) then
          iindex = self%geom%isc
          if (jindex.lt.self%geom%jec) then
            jindex = jindex + 1
          elseif (jindex.eq.self%geom%jec) then
            jindex = self%geom%jsc
            kindex = kindex + 1
          end if !j loop
        end if !iloop

        if (kindex > self%geom%kec) then
          iindex=-1
          jindex=-1
          kindex=-1
        end if !kloop
      case default
        call abor1_ftn('fv3jedi_geom_iter_next: unknown geom%iterator_dimension')
    end select

    self%iindex = iindex
    self%jindex = jindex
    self%kindex = kindex

  end subroutine fv3jedi_geom_iter_next
  ! ------------------------------------------------------------------------------

end module fv3jedi_geom_iter_mod
