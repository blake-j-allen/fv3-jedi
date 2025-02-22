! (C) Copyright 2017- UCAR
!
! This software is licensed under the terms of the Apache Licence Version 2.0
! which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.

module fv3jedi_io_cube_sphere_history_mod

! libs
use mpi
use netcdf

! fckit
use fckit_configuration_module, only: fckit_configuration
use fckit_mpi_module

! oops
use datetime_mod
use string_utils, only: swap_name_member, replace_string

! fv3-jedi
use fv3jedi_constants_mod,    only: constant
use fv3jedi_geom_mod,         only: fv3jedi_geom
use fv3jedi_field_mod,        only: fv3jedi_field, field_clen
use fv3jedi_io_utils_mod
use fv3jedi_kinds_mod,        only: kind_real
use fv3jedi_netcdf_utils_mod, only: nccheck
use fv3jedi_tile_comms_mod,   only: fv3jedi_tile_comms

implicit none
private
public fv3jedi_io_cube_sphere_history


! Variables derived from the configuration
! ----------------------------------------
type fv3jedi_io_csh_conf

  ! Provider (name of the model)
  character(len=96) :: provider

  ! Filenames to be read, provided as a list in the yaml
  character(len=:), allocatable :: filenames(:)

  ! Path to prepend all files with
  character(len=2048) :: datapath

  ! Option to clobber existing files
  logical, allocatable :: clobber(:)

  ! Optional list of fields to write out
  character(len=:), allocatable :: fields_to_write(:)

  ! NetCDF floating point type
  integer :: float_type

  ! By default the tile is a dimension in the file (npx by npy by ntile), alternatively the faces
  ! can be stacked in the y direction (npx by ntile*npy) by setting the following to false
  logical, allocatable :: tile_is_a_dimension(:)

  ! Names used to specify the dimensions in the file
  character(len=:), allocatable :: x_dimension_name(:)
  character(len=:), allocatable :: y_dimension_name(:)
  character(len=:), allocatable :: z_full_dimension_name(:)
  character(len=:), allocatable :: z_half_dimension_name(:)
  character(len=:), allocatable :: tile_dimension_name(:)
  character(len=:), allocatable :: x_var_name(:)
  character(len=:), allocatable :: x_var_long_name(:)
  character(len=:), allocatable :: x_var_units(:)
  character(len=:), allocatable :: y_var_name(:)
  character(len=:), allocatable :: y_var_long_name(:)
  character(len=:), allocatable :: y_var_units(:)

  ! Date/time checking
  logical :: set_datetime_on_read

end type fv3jedi_io_csh_conf


! IO Cubed Sphere History Class
! -----------------------------
type fv3jedi_io_cube_sphere_history

 ! Variables read from config
 type(fv3jedi_io_csh_conf) :: conf

 ! Number of files and ncid for each file
 integer :: nfiles
 integer, allocatable :: ncid(:)

 ! Absolute filenames
 character(len=2048), dimension(:), allocatable :: filenames
 character(len=2048), dimension(:), allocatable :: filenames_save

 ! Communicators for read/write gathering
 logical :: iam_io_proc
 type(fckit_mpi_comm) :: ccomm
 integer :: ocomm       !Communicator for each tile and for output
 integer :: crank, csize       !Component comm info
 integer :: orank, osize       !Output comm info

 ! Processor ranges
 integer :: is_r3_tile(5), ic_r3_tile(5)
 integer :: is_r2_tile(4), ic_r2_tile(4)
 integer :: is_r3_noti(4), ic_r3_noti(4)
 integer :: is_r2_noti(3), ic_r2_noti(3)
 integer :: vindex_tile
 integer :: vindex_noti = 3

 ! NetCDF dimension identifiers
 integer :: x_dimid, y_dimid, n_dimid, z_dimid, e_dimid, t_dimid, f_dimid, c_dimid, o_dimid, char_dimid

 ! Geometry copies
 integer :: isc, iec, jsc, jec
 integer :: npx, npy, npz, ntiles
 real(kind=kind_real), allocatable :: grid_lat(:,:), grid_lon(:,:)
 real(kind=kind_real), allocatable :: ak(:), bk(:)
 logical :: input_is_date_templated

 ! Tile comms
 type(fv3jedi_tile_comms) :: tile_comms

 contains
  procedure :: create
  procedure :: delete
  procedure :: read
  procedure :: write
  final     :: dummy_final

end type fv3jedi_io_cube_sphere_history

! --------------------------------------------------------------------------------------------------

contains

! --------------------------------------------------------------------------------------------------

subroutine create(self, geom, conf)

! Arguments
class(fv3jedi_io_cube_sphere_history), intent(inout) :: self
type(fv3jedi_geom),                    intent(in)    :: geom
type(fckit_configuration),             intent(in)    :: conf

! Locals
integer :: ierr, n, var, trank
integer :: tileoffset, dt_in_name
character(len=4) :: yyyy
character(len=2) :: mm, dd, hh, min, ss
character(len=:), allocatable :: str

! Parse the configuration
! -----------------------
call parse_conf(self, conf)


! Record number of files
! ----------------------
self%nfiles = size(self%conf%filenames)


! Identified for each file
! ------------------------
allocate(self%ncid(self%nfiles))


! Prepend the filenames with the path and swap any templated member numbers
! -------------------------------------------------------------------------
allocate(self%filenames(self%nfiles)) ! To be filled in later with datetime
allocate(self%filenames_save(self%nfiles))
do n = 1, self%nfiles
  self%filenames_save(n) = trim(self%conf%datapath)//'/'//trim(self%conf%filenames(n))
  ! Replace any double // with single / in the full filename
  self%filenames_save(n) = replace_string(self%filenames_save(n), '//', '/')
  str = self%filenames_save(n)
  call swap_name_member(conf, str)
  self%filenames_save(n) = str
enddo


! Component communicator / get the main communicator from fv3 geometry
! --------------------------------------------------------------------
self%ccomm = geom%f_comm
self%csize = self%ccomm%size()
self%crank = self%ccomm%rank()


! Split comm and set flag for IO procs
! ------------------------------------
self%iam_io_proc = .true.

if (self%csize > 6) then

  ! Create the tile communicator object
  call self%tile_comms%create(geom)
  trank = self%tile_comms%get_rank()

  ! Communicator for procs that will write, one per tile
  call mpi_comm_split(self%ccomm%communicator(), trank, geom%ntile, self%ocomm, ierr)
  call mpi_comm_rank(self%ocomm, self%orank, ierr)
  call mpi_comm_size(self%ocomm, self%osize, ierr)

  if (trank .ne. 0) self%iam_io_proc = .false.

else

  ! For 6 cores output comm is componenent comm
  call mpi_comm_dup(self%ccomm%communicator(), self%ocomm, ierr)

endif

! Create local to this proc start/count
! -------------------------------------
if (self%iam_io_proc) then

  ! Starts/counts with tile dimension
  self%is_r3_tile(1) = 1;           self%ic_r3_tile(1) = geom%npx-1  !X
  self%is_r3_tile(2) = 1;           self%ic_r3_tile(2) = geom%npy-1  !Y
  if (trim(self%conf%provider) == 'geos') then
    self%is_r3_tile(3) = geom%ntile;  self%ic_r3_tile(3) = 1           !Tile
    self%is_r3_tile(4) = 1;           self%ic_r3_tile(4) = 1           !Lev
    self%vindex_tile = 4
  else if (trim(self%conf%provider) == 'ufs') then
    self%is_r3_tile(3) = 1;           self%ic_r3_tile(3) = 1           !Lev
    self%is_r3_tile(4) = geom%ntile;  self%ic_r3_tile(4) = 1           !Tile
    self%vindex_tile = 3
  end if
  self%is_r3_tile(5) = 1;           self%ic_r3_tile(5) = 1           !Time
  self%is_r2_tile(1) = 1;           self%ic_r2_tile(1) = geom%npx-1
  self%is_r2_tile(2) = 1;           self%ic_r2_tile(2) = geom%npy-1
  self%is_r2_tile(3) = geom%ntile;  self%ic_r2_tile(3) = 1
  self%is_r2_tile(4) = 1;           self%ic_r2_tile(4) = 1

  ! Starts/counts with no tile dimension
  tileoffset = (geom%ntile-1)*(6*(geom%npy-1)/geom%ntiles)
  self%is_r3_noti(1) = 1;              self%ic_r3_noti(1) = geom%npx-1
  self%is_r3_noti(2) = tileoffset+1;   self%ic_r3_noti(2) = geom%npy-1
  self%is_r3_noti(3) = 1;              self%ic_r3_noti(3) = 1
  self%is_r3_noti(4) = 1;              self%ic_r3_noti(4) = 1
  self%is_r2_noti(1) = 1;              self%ic_r2_noti(1) = geom%npx-1
  self%is_r2_noti(2) = tileoffset+1;   self%ic_r2_noti(2) = geom%npy-1
  self%is_r2_noti(3) = 1;              self%ic_r2_noti(3) = 1
endif

! Copy some geometry for later use
self%isc = geom%isc
self%iec = geom%iec
self%jsc = geom%jsc
self%jec = geom%jec
self%npx = geom%npx
self%npy = geom%npy
self%npz = geom%npz
self%ntiles = geom%ntiles
allocate(self%grid_lat(geom%isc:geom%iec,geom%jsc:geom%jec))
allocate(self%grid_lon(geom%isc:geom%iec,geom%jsc:geom%jec))
self%grid_lat = constant('rad2deg')*geom%grid_lat(geom%isc:geom%iec,geom%jsc:geom%jec)
self%grid_lon = constant('rad2deg')*geom%grid_lon(geom%isc:geom%iec,geom%jsc:geom%jec)
allocate(self%ak(geom%npz+1))
allocate(self%bk(geom%npz+1))
self%ak = geom%ak
self%bk = geom%bk

end subroutine create

! --------------------------------------------------------------------------------------------------

subroutine parse_conf(self, conf)

! Arguments
type(fv3jedi_io_cube_sphere_history), intent(inout) :: self
type(fckit_configuration),            intent(in)    :: conf

! Locals
integer :: n, nfiles
character(len=:), allocatable :: str
character(len=96) :: conf_string

logical :: clobber_default
logical :: tile_is_a_dimension_default
character(len=96) :: x_dimension_name_default
character(len=96) :: y_dimension_name_default
character(len=96) :: z_full_dimension_name_default
character(len=96) :: z_half_dimension_name_default
character(len=96) :: tile_dimension_name_default
character(len=96) :: x_var_name_default
character(len=96) :: x_var_long_name_default
character(len=96) :: x_var_units_default
character(len=96) :: y_var_name_default
character(len=96) :: y_var_long_name_default
character(len=96) :: y_var_units_default
integer :: nbytes

! Provider
! --------
call conf%get_or_die('provider', str)
self%conf%provider = str


! Set the defaults
! ----------------
if (trim(self%conf%provider) == 'geos') then
  clobber_default = .true.
  tile_is_a_dimension_default = .true.
  x_dimension_name_default = "Xdim"
  y_dimension_name_default = "Ydim"
  z_full_dimension_name_default = "lev"
  z_half_dimension_name_default = "edge"
  tile_dimension_name_default = "nf"
  x_var_name_default = "lons"
  x_var_long_name_default = "longitude"
  x_var_units_default = "degrees_east"
  y_var_name_default = "lats"
  y_var_long_name_default = "latitude"
  y_var_units_default = "degrees_north"
endif

if (trim(self%conf%provider) == 'ufs') then
  clobber_default = .true.
  tile_is_a_dimension_default = .true.
  x_dimension_name_default = "grid_xt"
  y_dimension_name_default = "grid_yt"
  z_full_dimension_name_default = "pfull"
  z_half_dimension_name_default = "phalf"
  tile_dimension_name_default = "tile"
  x_var_name_default = "lon"
  x_var_long_name_default = "T-cell longitude"
  x_var_units_default = "degrees_E"
  y_var_name_default = "lat"
  y_var_long_name_default = "T-cell latitude"
  y_var_units_default = "degrees_N"
endif

! Files to be read
! ----------------
if (conf%has("filenames")) then
  call conf%get_or_die('filenames', self%conf%filenames)
elseif (conf%has("filename")) then
  call conf%get_or_die('filename', str)
  allocate(character(len=2048) :: self%conf%filenames(1))
  self%conf%filenames(1) = str
else
  call abor1_ftn("io_cube_sphere_history.parse_conf: config must contain either filenames or "// &
                 "filename if only one file is needed.")
endif
nfiles = size(self%conf%filenames)


! Datapath for all the files
! --------------------------
if (conf%has("datapath")) then
  call conf%get_or_die('datapath', str)
  self%conf%datapath = str
else
  self%conf%datapath = './'
endif


! Use clobber when writing files
! ------------------------------
call parse_conf_bool_array(conf, "clobber existing files", self%conf%clobber, &
                           clobber_default, nfiles)


! Whether to expect/use the tile dimenstion in the file
! -----------------------------------------------------
call parse_conf_bool_array(conf, "tile is a dimension", self%conf%tile_is_a_dimension, &
                           tile_is_a_dimension_default, nfiles)


! Dimension identities
! --------------------
call parse_conf_string_array(conf, "x dimension name", self%conf%x_dimension_name, &
                             x_dimension_name_default, nfiles)
call parse_conf_string_array(conf, "y dimension name", self%conf%y_dimension_name, &
                             y_dimension_name_default, nfiles)
call parse_conf_string_array(conf, "z full dimension name", self%conf%z_full_dimension_name, &
                             z_full_dimension_name_default, nfiles)
call parse_conf_string_array(conf, "z half dimension name", self%conf%z_half_dimension_name, &
                             z_half_dimension_name_default, nfiles)
call parse_conf_string_array(conf, "tile dimension name", self%conf%tile_dimension_name, &
                             tile_dimension_name_default, nfiles)
call parse_conf_string_array(conf, "x var name", self%conf%x_var_name, &
                             x_var_name_default, nfiles)
call parse_conf_string_array(conf, "x var long name", self%conf%x_var_long_name, &
                             x_var_long_name_default, nfiles)
call parse_conf_string_array(conf, "x var units", self%conf%x_var_units, &
                             x_var_units_default, nfiles)
call parse_conf_string_array(conf, "y var name", self%conf%y_var_name, &
                             y_var_name_default, nfiles)
call parse_conf_string_array(conf, "y var long name", self%conf%y_var_long_name, &
                             y_var_long_name_default, nfiles)
call parse_conf_string_array(conf, "y var units", self%conf%y_var_units, &
                             y_var_units_default, nfiles)


! Date/time checking
! ------------------
if (conf%has("set datetime on read")) then
  call conf%get_or_die('set datetime on read', self%conf%set_datetime_on_read)
else
  self%conf%set_datetime_on_read = .false.
endif

! are optional fields to write specified?
! ------------------
if (conf%has("fields to write")) then
  call conf%get_or_die('fields to write', self%conf%fields_to_write)
else
  allocate(character(len=2048) :: self%conf%fields_to_write(1))
  self%conf%fields_to_write(1)='All'
endif

! What is the floating point write precision in bytes for NetCDF?
! ---------------------------------------------------------------
if (conf%has('float precision in bytes')) then
   call conf%get_or_die('float precision in bytes', nbytes)
   select case (nbytes)
   case (1)
      self%conf%float_type = nf90_byte
   case (2)
      self%conf%float_type = nf90_short
   case (4)
      self%conf%float_type = nf90_float
   case (8)
      self%conf%float_type = nf90_double
   case default
      call abor1_ftn("Invalid floating point precision for NetCDF write")
   end select
else
   ! Default to double precision
   self%conf%float_type = nf90_double
end if

end subroutine parse_conf

! --------------------------------------------------------------------------------------------------

subroutine parse_conf_bool_array(conf, conf_key, bool_array, bool_array_default, array_size)

! Arguments
type(fckit_configuration), intent(in)    :: conf
character(len=*),          intent(in)    :: conf_key
logical, allocatable,      intent(inout) :: bool_array(:)
logical,                   intent(in)    :: bool_array_default
integer,                   intent(in)    :: array_size

! Get array from config or set to default
if (conf%has(trim(conf_key))) then
  call conf%get_or_die(trim(conf_key), bool_array)
else
  allocate(bool_array(array_size))
  bool_array = bool_array_default
endif

! Assert that the length is correct
if (array_size .ne. size(bool_array)) &
  call abor1_ftn("io_cube_sphere_history.parse_conf_bool_array: config key "//conf_key//" is "// &
                 "providing an array that is inconsistent with the number of files.")

end subroutine parse_conf_bool_array

! --------------------------------------------------------------------------------------------------

subroutine parse_conf_string_array(conf, conf_key, str_array, str_array_default, array_size)

! Arguments
type(fckit_configuration),     intent(in)    :: conf
character(len=*),              intent(in)    :: conf_key
character(len=:), allocatable, intent(inout) :: str_array(:)
character(len=*),              intent(in)    :: str_array_default
integer,                       intent(in)    :: array_size

! Get array from config or set to default
if (conf%has(trim(conf_key))) then
  call conf%get_or_die(trim(conf_key), str_array)
else
  allocate(character(len=2048) :: str_array(array_size))
  str_array = str_array_default
endif

! Assert that the length is correct
if (array_size .ne. size(str_array)) &
  call abor1_ftn("io_cube_sphere_history.parse_conf_string_array: config key "//conf_key//" is "// &
                 "providing an array that is inconsistent with the number of files.")

end subroutine parse_conf_string_array

! --------------------------------------------------------------------------------------------------

subroutine delete(self)

! Arguments
class(fv3jedi_io_cube_sphere_history), intent(inout) :: self

! Locals
integer :: ierr

! Deallocate config variables
! ---------------------------
deallocate(self%conf%filenames)
deallocate(self%conf%clobber)
deallocate(self%conf%tile_is_a_dimension)
deallocate(self%conf%x_dimension_name)
deallocate(self%conf%y_dimension_name)
deallocate(self%conf%z_full_dimension_name)
deallocate(self%conf%z_half_dimension_name)
deallocate(self%conf%tile_dimension_name)

! Deallocate
! ----------
deallocate(self%ncid)
deallocate(self%filenames)
deallocate(self%grid_lat)
deallocate(self%grid_lon)
deallocate(self%ak)
deallocate(self%bk)

! Release split comms
! -------------------
if (self%csize > 6) call self%tile_comms%delete()
call MPI_Comm_free(self%ocomm, ierr)

end subroutine delete

! --------------------------------------------------------------------------------------------------

subroutine read(self, vdate, fields)

! Arguments
class(fv3jedi_io_cube_sphere_history), intent(inout) :: self
type(datetime),                        intent(in)    :: vdate
type(fv3jedi_field),                   intent(inout) :: fields(:)

! Overwrite any datetime templates in the file names
! --------------------------------------------------
call set_datetime_in_filenames(self, vdate)

! Open files
! ----------
call open_files(self)

! Check datetime of the files matches the one set from config
! -----------------------------------------------------------
call check_datetime(self, vdate)

! Read fields
! -----------
call read_fields(self, fields)

! Close files
! -----------
call close_files(self)

end subroutine read

! --------------------------------------------------------------------------------------------------

subroutine write(self, vdate, fields)

! Arguments
class(fv3jedi_io_cube_sphere_history), intent(inout) :: self
type(datetime),                        intent(in)    :: vdate
type(fv3jedi_field),                   intent(in)    :: fields(:)

! Assert that there is only one file for writing
! ----------------------------------------------
if (self%nfiles .ne. 1) &
  call abor1_ftn("io_cube_sphere_history.write: Only one file can be written to")

! Overwrite any datetime templates in the file names
! --------------------------------------------------
call set_datetime_in_filenames(self, vdate)

! Open/create files
! -----------------
call create_files(self)

! Write meta data
! ---------------
if (any(self%conf%clobber)) call write_meta(self, fields, vdate)

! Write fields
! ------------
call write_fields(self, fields, vdate)

! Close files
! -----------
call close_files(self)

end subroutine write

! --------------------------------------------------------------------------------------------------

subroutine set_datetime_in_filenames(self, vdate)

! Arguments
type(fv3jedi_io_cube_sphere_history), intent(inout) :: self
type(datetime),                       intent(in)    :: vdate

! Locals
integer :: n
character(len=4) :: yyyy
character(len=2) :: mm, dd, hh, min, ss

! Datetime to strings
! -------------------
call vdate_to_datestring(vdate, yyyy=yyyy, mm=mm, dd=dd, hh=hh, min=min, ss=ss)

do n = 1, self%nfiles

  self%filenames(n) = self%filenames_save(n)

  ! Config filenames to filenames
  ! -----------------------------
  ! Swap out datetime templates if needed
  if (index(self%filenames(n),"%yyyy") > 0) &
    self%filenames(n) = trim(replace_text(self%filenames(n),'%yyyy',yyyy))
  if (index(self%filenames(n),"%mm"  ) > 0) &
    self%filenames(n) = trim(replace_text(self%filenames(n),'%mm'  ,mm  ))
  if (index(self%filenames(n),"%dd"  ) > 0) &
    self%filenames(n) = trim(replace_text(self%filenames(n),'%dd'  ,dd  ))
  if (index(self%filenames(n),"%hh"  ) > 0) &
    self%filenames(n) = trim(replace_text(self%filenames(n),'%hh'  ,hh  ))
  if (index(self%filenames(n),"%MM"  ) > 0) &
    self%filenames(n) = trim(replace_text(self%filenames(n),'%MM'  ,min ))
  if (index(self%filenames(n),"%ss"  ) > 0) &
    self%filenames(n) = trim(replace_text(self%filenames(n),'%ss'  ,ss  ))

enddo

end subroutine set_datetime_in_filenames

! --------------------------------------------------------------------------------------------------

subroutine check_datetime(self, vdate)

! Arguments
type(fv3jedi_io_cube_sphere_history), intent(in) :: self
type(datetime),                       intent(in) :: vdate

! Locals
integer :: varid, intdate, inttime
character(len=8) :: cdate
character(len=6) :: ctime
integer :: n
character(len=64) :: vdate_string_file, vdate_string
character(len=20) :: time_str

! Do not check date/time if set on read
if (self%conf%set_datetime_on_read) return

! This reads the datetime from the first file in the list and checks against datetime already set

! Compute string form of the datetime in the fields
call datetime_to_string(vdate, vdate_string)

if (self%iam_io_proc) then

  ! Read only the first file in the list
  if (trim(self%conf%provider) == 'geos') then
    call nccheck ( nf90_inq_varid(self%ncid(1), "time", varid), "nf90_inq_varid time" )
    call nccheck ( nf90_get_att(self%ncid(1), varid, "begin_date", intdate), &
                   "nf90_get_att begin_date" )
    call nccheck ( nf90_get_att(self%ncid(1), varid, "begin_time", inttime), &
                   "nf90_get_att begin_time" )
  else if (trim(self%conf%provider) == 'ufs') then
    call nccheck ( nf90_inq_varid(self%ncid(1), "time_iso", varid), "nf90_inq_varid time" )
    call nccheck ( nf90_get_var( self%ncid(1), varid, time_str), &
                  "nf90_get_var time" )
  end if

endif

if (trim(self%conf%provider) == 'geos') then
  ! Send to all processors
  call self%ccomm%broadcast(intdate,0)
  call self%ccomm%broadcast(inttime,0)

  ! Pad and convert to string
  write(cdate,"(I0.8)") intdate  ! Looks like YYYYMMDD
  write(ctime,"(I0.6)") inttime  ! Looks like HHmmSS

  ! Convert to string that matches format returned by datetime_to_string YYYY-MM-DDTHH:mm:SS
  vdate_string_file = cdate(1:4)//'-'//cdate(5:6)//'-'//cdate(7:8)//'T'// &
                      ctime(1:2)//':'//ctime(3:4)//':'//ctime(5:6)//'Z'
else if (trim(self%conf%provider) == 'ufs') then
  call self%ccomm%broadcast(time_str,0)
  vdate_string_file = time_str
end if

! Assert
if (trim(vdate_string_file) .ne. trim(vdate_string)) &
  call abor1_ftn("io_cube_sphere_history.read.check_datetime: Datetime set in fields (" &
                 //trim(vdate_string)//") does not match that read from the file (" &
                 //trim(vdate_string_file)//"). File being read: "//trim(self%filenames(1)))

end subroutine check_datetime

! --------------------------------------------------------------------------------------------------

subroutine read_fields(self, fields)

! Arguments
type(fv3jedi_io_cube_sphere_history), target, intent(inout) :: self
type(fv3jedi_field),                          intent(inout) :: fields(:)

! Locals
integer, allocatable :: file_index(:), varid(:)
integer :: var, n, maxlev
logical :: tile_is_a_dimension
integer, pointer :: istart(:), icount(:)
real(kind=kind_real), allocatable :: arrayg(:,:,:)

! Get ncid and varid for each field
! ---------------------------------
allocate(file_index(size(fields)))
allocate(varid(size(fields)))

! Get variable IDs
call get_field_ncid_varid(self, fields, file_index, varid)

! Get max levels
! --------------
call get_max_levels(fields, maxlev)

! Loop over fields
! ----------------
do var = 1,size(fields)

  ! Set pointers to the appropriate array ranges
  ! --------------------------------------------
  if (self%iam_io_proc) then

    ! Check if tile is a dimension for file housing this variable
    tile_is_a_dimension = self%conf%tile_is_a_dimension(file_index(var))

    ! Nullify any existing pointers
    if (associated(istart)) nullify(istart)
    if (associated(icount)) nullify(icount)

    ! Change the counts to match the correct number of levels for 3D fields
    if (fields(var)%npz > 1) then
      self%ic_r3_tile(self%vindex_tile) = fields(var)%npz
      self%ic_r3_noti(self%vindex_noti) = fields(var)%npz
    endif

    ! Set istart and icount based on whether field is rank 2 or rank 3 and whether tile is a dimension
    if (fields(var)%npz == 1) then
      if (tile_is_a_dimension) then
        istart => self%is_r2_tile
        icount => self%ic_r2_tile
      else
        istart => self%is_r2_noti
        icount => self%ic_r2_noti
      endif
    elseif (fields(var)%npz > 1) then
      if (tile_is_a_dimension) then
        istart => self%is_r3_tile
        icount => self%ic_r3_tile
      else
        istart => self%is_r3_noti
        icount => self%ic_r3_noti
      endif
    endif

    ! Whole tile array that can accomodate any of the fields
    ! ------------------------------------------------------
    if (.not.allocated(arrayg)) allocate(arrayg(1:self%npx-1,1:self%npy-1,1:maxlev))
    arrayg = 0.0_kind_real

    ! If not a concatenated field, read all levels
    call nccheck ( nf90_get_var( self%ncid(file_index(var)), varid(var), &
                   arrayg(1:self%npx-1,1:self%npy-1,1:fields(var)%npz), istart, icount), &
                   "nf90_get_var "//trim(fields(var)%io_name) )

  endif

  ! Scatter the field to all processors on the tile
  ! -----------------------------------------------
  if (self%csize > 6) then
    call self%tile_comms%scatter_tile(fields(var)%npz, arrayg, &
                           fields(var)%array(self%isc:self%iec,self%jsc:self%jec,1:fields(var)%npz))
  else
    fields(var)%array(self%isc:self%iec,self%jsc:self%jec,1:fields(var)%npz) = &
                                       arrayg(self%isc:self%iec,self%jsc:self%jec,1:fields(var)%npz)
  endif

enddo

end subroutine read_fields

! --------------------------------------------------------------------------------------------------

subroutine get_max_levels(fields, maxlev)

! Arguments
type(fv3jedi_field), intent(in)  :: fields(:)
integer,             intent(out) :: maxlev

! Locals
integer :: f

maxlev = 0
do f = 1, size(fields)
  maxlev = max(maxlev, fields(f)%npz)
end do

end subroutine get_max_levels

! --------------------------------------------------------------------------------------------------

subroutine get_field_ncid_varid(self, fields, file_index, varid)

! Arguments
type(fv3jedi_io_cube_sphere_history), intent(in)    :: self
type(fv3jedi_field),                  intent(in)    :: fields(:)
integer,                              intent(inout) :: file_index(size(fields(:)))
integer,                              intent(inout) :: varid(size(fields(:)))

! Locals
integer :: f, ff, n
integer :: status, varid_local
integer, allocatable :: found(:)
logical :: matches_io_file

! Array to keep track of all the files the variable was found in
allocate(found(self%nfiles))

do f = 1, size(fields)

  found = 0

  do n = 1, self%nfiles

     ! Check if filename matches IO file specified in fields metadata
     matches_io_file = .true. ! Default to true for unknown or unspecified provider
     if ( trim(self%conf%provider) == 'ufs' ) then
        select case ( trim(fields(f)%io_file) )
        case ( 'default' ) ! No IO file specified in metadata for this field
           matches_io_file = .true.
        case ( 'surface' )
           matches_io_file = ( index(trim(self%filenames(n)),'sfc') /= 0 )
        case ( 'atmosphere' )
           matches_io_file = ( index(trim(self%filenames(n)),'atm') /= 0 )
        case default ! Unknown IO file
           call abor1_ftn( "fv3jedi_io_cube_sphere_history_mod error: Unknown IO file for field, " // trim(fields(f)%long_name) )
        end select
     end if

     if ( matches_io_file ) then
        ! Get the varid
        status = nf90_inq_varid(self%ncid(n), fields(f)%io_name, varid_local)

        ! If found then fill the array
        if (status == nf90_noerr) then
           found(n) = 1
           file_index(f) = n
           varid(f) = varid_local
        endif
     end if
  enddo

  ! Check that the field was not found more than once
  if (sum(found) > 1) &
       call abor1_ftn("fv3jedi_io_cube_sphere_history_mod.read_fields.get_field_ncid_varid: "// &
                      "Field "//trim(fields(f)%io_name)//" was found in multiple input files. "// &
                      "Should only be present in one file that is read.")

  ! Check that the field was found
  if (sum(found) == 0) then
     call abor1_ftn("fv3jedi_io_cube_sphere_history_mod.read_fields.get_field_ncid_varid: "// &
                    "Field "//trim(fields(f)%io_name)//" was not found in any files. "// &
                    "Should only be present in one file that is read.")
  end if
enddo

end subroutine get_field_ncid_varid

! --------------------------------------------------------------------------------------------------

subroutine write_meta(self, fields, vdate)

! Arguments
type(fv3jedi_io_cube_sphere_history), target, intent(inout) :: self
type(fv3jedi_field),                          intent(in)    :: fields(:)
type(datetime),                               intent(in)    :: vdate

! Locals
integer :: var, ymult, k, n, vc
character(len=15)  :: datefile
integer :: date(6), date8, time6
character(len=8)   :: date8s, cubesize
character(len=6)   :: time6s
character(len=19)  :: ufstimestr
character(len=20)  :: isotimestr
character(len=24)  :: XdirVar, YdirVar, ZfulVar, ZhlfVar, TileVar
character(len=24)  :: XVarStr, XLongName, XUnits, YVarStr, YLongName, YUnits
integer :: varid(10000)

integer, pointer :: istart(:), icount(:)
integer, allocatable :: dimidsg(:), tiles(:), levels(:), layers(:)
real(kind=kind_real), allocatable :: latg(:,:), long(:,:), xdimydim(:)


! Gathered lats/lons
! ------------------
if (self%iam_io_proc) then
  allocate(latg(1:self%npx-1,1:self%npy-1))
  allocate(long(1:self%npx-1,1:self%npy-1))
endif

if (self%csize > 6) then
  call self%tile_comms%gather_tile(self%grid_lat, latg)
  call self%tile_comms%gather_tile(self%grid_lon, long)
else
  latg = self%grid_lat
  long = self%grid_lon
endif

write(cubesize,'(I8)') self%npx-1

! IO processors write the metadata
! --------------------------------
if (self%iam_io_proc) then

  ! Get datetime information ready to write
  ! ---------------------------------------
  call vdate_to_datestring(vdate,datest=datefile,isodate=isotimestr,ufsdate=ufstimestr,date=date)
  write(date8s,'(I4,I0.2,I0.2)')   date(1),date(2),date(3)
  write(time6s,'(I0.2,I0.2,I0.2)') date(4),date(5),date(6)
  read(date8s,*) date8
  read(time6s,*) time6


  ! Xdim, Ydim arrays
  ! -----------------
  allocate(xdimydim(self%npx-1))
  do k = 1,self%npx-1
    xdimydim(k) = real(k,kind_real)
  enddo


  ! Tile array
  ! ----------
  allocate(tiles(6))
  do k = 1,6
    tiles(k) = k
  enddo


  ! Level and edge arrays
  ! ---------------------
  allocate(levels(self%npz+1))
  allocate(layers(self%npz))
  if (trim(self%conf%provider) == 'geos') then
    do k = 1,self%npz+1
      levels(k) = k
    enddo
    layers = levels(1:self%npz)
  else if (trim(self%conf%provider) == 'ufs') then
    do k = 1,self%npz+1
      levels(k) = (self%ak(k) + self%bk(k)*1.0e5)/100.
    enddo
    do k = 1,self%npz
      layers(k) = (levels(k) + levels(k+1))/2. ! simple averaging for now
    end do
  end if


  ! Loop over all files to be created/written to
  ! --------------------------------------------
  do n = 1, self%nfiles

    if (self%conf%clobber(n)) then

      ! Multiplication factor when no tile dimension
      ! --------------------------------------------
      ymult = 1
      if (.not. self%conf%tile_is_a_dimension(n)) ymult = 6

      XdirVar = self%conf%x_dimension_name(n)
      YdirVar = self%conf%y_dimension_name(n)
      ZfulVar = self%conf%z_full_dimension_name(n)
      ZhlfVar = self%conf%z_half_dimension_name(n)
      TileVar = self%conf%tile_dimension_name(n)
      XVarStr = self%conf%x_var_name(n)
      XLongName = self%conf%x_var_long_name(n)
      XUnits = self%conf%x_var_units(n)
      YVarStr = self%conf%y_var_name(n)
      YLongName = self%conf%y_var_long_name(n)
      YUnits = self%conf%y_var_units(n)

      ! Main dimensions
      call nccheck ( nf90_def_dim(self%ncid(n), trim(XdirVar), self%npx-1,         self%x_dimid), &
                     "nf90_def_dim "//trim(XdirVar) )
      call nccheck ( nf90_def_dim(self%ncid(n), trim(YdirVar), ymult*(self%npy-1), self%y_dimid), &
                     "nf90_def_dim "//trim(YdirVar) )
      call nccheck ( nf90_def_dim(self%ncid(n), trim(ZfulVar), self%npz,           self%z_dimid), &
                     "nf90_def_dim "//trim(ZfulVar) )
      call nccheck ( nf90_def_dim(self%ncid(n), trim(ZhlfVar), self%npz+1,         self%e_dimid), &
                     "nf90_def_dim "//trim(ZhlfVar) )

      ! Tile dimension
      if (self%conf%tile_is_a_dimension(n)) &
        call nccheck ( nf90_def_dim(self%ncid(n), trim(TileVar),  self%ntiles, self%n_dimid), &
                       "nf90_def_dim "//trim(TileVar) )

      ! Time dimension
      call nccheck ( nf90_def_dim(self%ncid(n), "time", 1, self%t_dimid), "nf90_def_dim time" )

      ! In case that UFS multi-level surface fields need to be written
      do var = 1,size(fields)
        if (fields(var)%npz == 4) then
          call nccheck ( nf90_def_dim(self%ncid(n), "lev4", 4, self%f_dimid), "nf90_def_dim lev"  )
          exit
        endif
      enddo

      if (trim(self%conf%provider) == 'geos') then
        ! Meta data required by the model
        call nccheck ( nf90_def_dim(self%ncid(n), "ncontact",          4, self%c_dimid), &
                       "nf90_def_dim ncontact" )
        call nccheck ( nf90_def_dim(self%ncid(n), "orientationStrLen", 5, self%o_dimid), &
                       "nf90_def_dim orientationStrLend" )
      else if (trim(self%conf%provider) == 'ufs') then
        ! dimension for iso time string
        call nccheck ( nf90_def_dim(self%ncid(n), "nchars", 20, self%char_dimid), &
                       "nf90_def_dim nchars")
      end if

      ! Dimension ID array for lat/lon arrays
      if (allocated(dimidsg)) deallocate(dimidsg)
      if ( self%conf%tile_is_a_dimension(n) ) then
        allocate(dimidsg(3))
        dimidsg(:) = (/ self%x_dimid, self%y_dimid, self%n_dimid /)
      else
        allocate(dimidsg(2))
        dimidsg(:) = (/ self%x_dimid, self%y_dimid /)
      endif

      ! Define fields to be written
      vc=0;

      if (self%conf%tile_is_a_dimension(n)) then
        vc=vc+1;
        call nccheck( nf90_def_var(self%ncid(n), trim(TileVar), NF90_INT, self%n_dimid, varid(vc)), &
                      "nf90_def_var "//trim(TileVar) )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", "cubed-sphere face") )
        if (trim(self%conf%provider) == 'geos') then
          call nccheck( nf90_put_att(self%ncid(n), varid(vc), "axis", "e") )
          call nccheck( nf90_put_att(self%ncid(n), varid(vc), "grads_dim", "e") )
        end if
      endif

      vc=vc+1;
      call nccheck( nf90_def_var(self%ncid(n), trim(XdirVar), self%conf%float_type, self%x_dimid, varid(vc)), &
                    "nf90_def_var "//trim(XdirVar) )
      if (trim(self%conf%provider) == 'geos') then
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", &
                      "Fake Longitude for GrADS Compatibility") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "units", "degrees_east") )
      else if (trim(self%conf%provider) == 'ufs') then
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "cartesian_axis", "X") )
      end if

      vc=vc+1;
      call nccheck( nf90_def_var(self%ncid(n), trim(YdirVar), self%conf%float_type, self%y_dimid, varid(vc)), &
                    "nf90_def_var "//trim(YdirVar) )
      if (trim(self%conf%provider) == 'geos') then
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", &
                      "Fake Latitude for GrADS Compatibility") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "units", "degrees_north") )
      else if (trim(self%conf%provider) == 'ufs') then
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "cartesian_axis", "Y") )
      end if

      vc=vc+1;
      call nccheck( nf90_def_var(self%ncid(n), trim(XVarStr), self%conf%float_type, dimidsg, varid(vc)), &
                    "nf90_def_var "//trim(XVarStr) )
      call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", trim(XLongName)) )
      call nccheck( nf90_put_att(self%ncid(n), varid(vc), "units", trim(XUnits) ) )

      vc=vc+1;
      call nccheck( nf90_def_var(self%ncid(n), trim(YVarStr), self%conf%float_type, dimidsg, varid(vc)), &
                    "nf90_def_var "//trim(YVarStr) )
      call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", trim(YLongName)) )
      call nccheck( nf90_put_att(self%ncid(n), varid(vc), "units", trim(YUnits) ) )

      vc=vc+1;
      call nccheck( nf90_def_var(self%ncid(n), trim(ZfulVar), self%conf%float_type, self%z_dimid, varid(vc)), &
                    "nf90_def_var "//trim(ZfulVar) )
      call nccheck( nf90_put_att(self%ncid(n), varid(vc), "positive", "down") )
      if (trim(self%conf%provider) == 'geos') then
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", "vertical level") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "units", "layer") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "coordinate", "eta") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "standard_name", "model_layers") )
      else if (trim(self%conf%provider) == 'ufs') then
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", "ref full pressure level") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "units", "mb") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "edges", "phalf") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "cartesian_axis", "Z") )
      end if

      vc=vc+1;
      call nccheck( nf90_def_var(self%ncid(n), trim(ZhlfVar), self%conf%float_type, self%e_dimid, varid(vc)), &
                    "nf90_def_var "//trim(ZhlfVar) )
      call nccheck( nf90_put_att(self%ncid(n), varid(vc), "positive", "down") )
      if (trim(self%conf%provider) == 'geos') then
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", "vertical level edges") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "units", "layer") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "coordinate", "eta") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "standard_name", "model_layers") )
      else if (trim(self%conf%provider) == 'ufs') then
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", "ref half pressure level") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "units", "mb") )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "cartesian_axis", "Z") )
      end if

      vc=vc+1;
      if (trim(self%conf%provider) == 'geos') then
        call nccheck( nf90_def_var(self%ncid(n), "time", NF90_INT, self%t_dimid, varid(vc)), "nf90_def_var time" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", "time"), "nf90_def_var time long_name" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "begin_date", date8), "nf90_def_var time begin_date" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "begin_time", time6), "nf90_def_var time begin_time" )
      else if (trim(self%conf%provider) == 'ufs') then
        call nccheck( nf90_def_var(self%ncid(n), "time", self%conf%float_type, self%t_dimid, varid(vc)), "nf90_def_var time" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", "time"), "nf90_def_var time long_name" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "calendar", "JULIAN"), "nf90_def_var time calendar" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "calendar_type", "JULIAN"), "nf90_def_var time calendar_type" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "cartesian_axis", "T"), "nf90_def_var time cartesian_axis" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "units", "hours since "//ufstimestr), "nf90_def_var time units" )
        vc=vc+1;
        call nccheck( nf90_def_var(self%ncid(n), "time_iso", NF90_CHAR, (/self%char_dimid,self%t_dimid/), varid(vc)), &
                      "nf90_def_var iso_time" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "long_name", "valid time"), "nf90_def_var iso_time long_name" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "description", "ISO 8601 datetime string"), &
                      "nf90_def_var iso_time description" )
      end if

      if (trim(self%conf%provider) == 'geos') then
        vc=vc+1; !(Needed to ingest cube sphere)
        call nccheck( nf90_def_var(self%ncid(n), "cubed_sphere", NF90_CHAR, varid(vc)), &
                      "nf90_def_var cubed_sphere" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "grid_mapping_name", "gnomonic cubed-sphere"), &
                      "nf90_def_var time grid_mapping_name" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "file_format_version", "2.90"), &
                      "nf90_def_var time file_format_version" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "additional_vars", "contacts,orientation,anchor"), &
                      "nf90_def_var time additional_vars" )
        call nccheck( nf90_put_att(self%ncid(n), varid(vc), "gridspec_file", "C"//trim(cubesize)//"_gridspec.nc4"), &
                      "nf90_def_var gridspec_file" )
      end if

      if (trim(self%conf%provider) == 'ufs') then
        ! add global attributes
        call nccheck( nf90_put_att(self%ncid(n), NF90_GLOBAL, "ak", real(self%ak)), "nf90_put_att ak")
        call nccheck( nf90_put_att(self%ncid(n), NF90_GLOBAL, "bk", real(self%bk)), "nf90_put_att bk")
        call nccheck( nf90_put_att(self%ncid(n), NF90_GLOBAL, "source", "FV3-JEDI"), "nf90_put_att source")
        call nccheck( nf90_put_att(self%ncid(n), NF90_GLOBAL, "grid", "cubed_sphere"), "nf90_put_att grid")
        call nccheck( nf90_put_att(self%ncid(n), NF90_GLOBAL, "grid_id", 1), "nf90_put_att grid_id")
        call nccheck( nf90_put_att(self%ncid(n), NF90_GLOBAL, "ncnsto", 9), "nf90_put_att ncnsto") ! get this from somewhere?
        call nccheck( nf90_put_att(self%ncid(n), NF90_GLOBAL, "hydrostatic", "non-hydrostatic"), "nf90_put_att hydrostatic")
      end if


      ! End define mode
      ! ---------------
      call nccheck( nf90_enddef(self%ncid(n)), "nf90_enddef" )


      ! Reset counter
      ! -------------
      vc=0


      ! Write metadata arrays
      ! ---------------------

      ! Tiles
      if (self%conf%tile_is_a_dimension(n)) then
        vc=vc+1
        call nccheck( nf90_put_var( self%ncid(n), varid(vc), tiles ), "nf90_put_var "//trim(TileVar) )
      endif

      ! Xdim & Ydim arrays
      vc=vc+1;call nccheck( nf90_put_var( self%ncid(n), varid(vc), xdimydim ), &
                            "nf90_put_var "//trim(XdirVar) )
      vc=vc+1;call nccheck( nf90_put_var( self%ncid(n), varid(vc), xdimydim ), &
                            "nf90_put_var "//trim(YdirVar) )

      ! Start/counts
      if (associated(istart)) nullify(istart)
      if (associated(icount)) nullify(icount)
      if (self%conf%tile_is_a_dimension(n)) then
        istart => self%is_r2_tile(1:3); icount => self%ic_r2_tile(1:3)
      else
        istart => self%is_r2_noti(1:2); icount => self%ic_r2_noti(1:2)
      endif

      ! Lat/lon arrays
      vc=vc+1;call nccheck( nf90_put_var( self%ncid(n), varid(vc), long, &
                                                  start = istart, &
                                                  count = icount ), &
                                                  "nf90_put_var lons" )

      vc=vc+1;call nccheck( nf90_put_var( self%ncid(n), varid(vc), latg, &
                                                  start = istart, &
                                                  count = icount ), &
                                                  "nf90_put_var lats" )

      ! Write model levels & time
      vc=vc+1;call nccheck( nf90_put_var( self%ncid(n), varid(vc), layers ), &
                            "nf90_put_var "//trim(ZfulVar) )
      vc=vc+1;call nccheck( nf90_put_var( self%ncid(n), varid(vc), levels ), &
                            "nf90_put_var "//trim(ZhlfVar) )

      ! Time
      vc=vc+1;call nccheck( nf90_put_var( self%ncid(n), varid(vc), 0 ), "nf90_put_var time" )

      if (trim(self%conf%provider) == 'ufs') then
        ! ISO 8601 time string
        vc=vc+1; call nccheck( nf90_put_var( self%ncid(n), varid(vc), isotimestr), "nf90_put_var iso_time")
      end if
    endif

  enddo

endif

end subroutine write_meta

! --------------------------------------------------------------------------------------------------

subroutine write_fields(self, fields, vdate)

! Arguments
type(fv3jedi_io_cube_sphere_history), target, intent(inout) :: self
type(fv3jedi_field),                          intent(in)    :: fields(:)
type(datetime),                               intent(in)    :: vdate

! Locals
integer :: var, n, ncid, maxlev
integer, target :: dimids2_tile(4), dimids3_tile(5), dimidse_tile(5), dimids4_tile(5)
integer, target :: dimids2_noti(3), dimids3_noti(4), dimidse_noti(4), dimids4_noti(4)
integer, pointer :: dimids2(:), dimids3(:), dimidse(:), dimids4(:), dimids(:)
real(kind=kind_real), allocatable :: arrayg(:,:,:)
integer, pointer :: istart(:), icount(:)
integer :: varid
character(10) :: coordstr
logical :: write_field


! Get max levels
! --------------
call get_max_levels(fields, maxlev)

! Dimension ID arrays for the various fields with and without tile dimension
! --------------------------------------------------------------------------
if (trim(self%conf%provider) == 'geos') then
  dimids2_tile = (/ self%x_dimid, self%y_dimid, self%n_dimid,               self%t_dimid /)
  dimids3_tile = (/ self%x_dimid, self%y_dimid, self%n_dimid, self%z_dimid, self%t_dimid /)
  dimidse_tile = (/ self%x_dimid, self%y_dimid, self%n_dimid, self%e_dimid, self%t_dimid /)
  dimids4_tile = (/ self%x_dimid, self%y_dimid, self%n_dimid, self%f_dimid, self%t_dimid /)

  dimids2_noti = (/ self%x_dimid, self%y_dimid,                             self%t_dimid /)
  dimids3_noti = (/ self%x_dimid, self%y_dimid,               self%z_dimid, self%t_dimid /)
  dimidse_noti = (/ self%x_dimid, self%y_dimid,               self%e_dimid, self%t_dimid /)
  dimids4_noti = (/ self%x_dimid, self%y_dimid,               self%f_dimid, self%t_dimid /)
else if (trim(self%conf%provider) == 'ufs') then
  dimids2_tile = (/ self%x_dimid, self%y_dimid, self%n_dimid,               self%t_dimid /)
  dimids3_tile = (/ self%x_dimid, self%y_dimid, self%z_dimid, self%n_dimid, self%t_dimid /)
  dimidse_tile = (/ self%x_dimid, self%y_dimid, self%e_dimid, self%n_dimid, self%t_dimid /)
  dimids4_tile = (/ self%x_dimid, self%y_dimid, self%f_dimid, self%n_dimid, self%t_dimid /)
end if

! UFS/GEOS specific things
! ------------------------
if (trim(self%conf%provider) == 'geos') then
  coordstr = "lons lats"
else if (trim(self%conf%provider) == 'ufs') then
  coordstr = "lon lat"
end if

! Loop over the fields
! --------------------
do var = 1,size(fields)

  write_field = .false.
  if (trim(self%conf%fields_to_write(1)) == 'All') then
    write_field = .true.
  else
    do n = 1,size(self%conf%fields_to_write)
      if (trim(self%conf%fields_to_write(n)) == trim(fields(var)%io_name)) then
        write_field = .true.
      end if
    end do
  end if

  if (write_field) then
    if (self%iam_io_proc) then

      ! ncid for this field
      ! -------------------
      ncid = self%ncid(1)

      ! Redefine
      ! --------
      if (self%conf%clobber(1)) then

        call nccheck( nf90_redef(ncid), "nf90_redef" )

        ! Dimension IDs for this field
        ! ----------------------------
        if (associated(dimids2)) nullify(dimids2)
        if (associated(dimids3)) nullify(dimids3)
        if (associated(dimidse)) nullify(dimidse)
        if (associated(dimids4)) nullify(dimids4)

        if (self%conf%tile_is_a_dimension(1)) then
          dimids2 => dimids2_tile
          dimids3 => dimids3_tile
          dimidse => dimidse_tile
          dimids4 => dimids4_tile
        else
          dimids2 => dimids2_noti
          dimids3 => dimids3_noti
          dimidse => dimidse_noti
          dimids4 => dimids4_noti
        endif

        if (associated(dimids)) nullify (dimids)

        if (fields(var)%npz == 1 ) then
          dimids => dimids2
        elseif (fields(var)%npz == 4 ) then
          dimids => dimids4
        elseif (fields(var)%npz == self%npz) then
          dimids => dimids3
        elseif (fields(var)%npz == self%npz+1) then
          dimids => dimidse
        else
          call abor1_ftn("write_cube_sphere_history: vertical dimension not supported")
        endif

        ! Define field
        call nccheck( nf90_def_var(ncid, trim(fields(var)%io_name), self%conf%float_type, dimids, varid), &
                       "nf90_def_var "//trim(fields(var)%io_name))

        ! Long name and units
        call nccheck( nf90_put_att(ncid, varid, "long_name"    , trim(fields(var)%long_name) ), "nf90_put_att" )
        call nccheck( nf90_put_att(ncid, varid, "units"        , trim(fields(var)%units)     ), "nf90_put_att" )

        ! Additional attributes for history and or plotting compatibility
        call nccheck( nf90_put_att(ncid, varid, "standard_name", trim(fields(var)%long_name) ), "nf90_put_att" )
        call nccheck( nf90_put_att(ncid, varid, "coordinates"  , trim(coordstr)              ), "nf90_put_att" )
        call nccheck( nf90_put_att(ncid, varid, "grid_mapping" , "cubed_sphere"              ), "nf90_put_att" )

        ! End define mode
        call nccheck( nf90_enddef(ncid), "nf90_enddef" )

      else  ! No clobber

        ! Get existing variable id to write to
        call nccheck ( nf90_inq_varid (ncid, trim(fields(var)%io_name), varid), &
                       "nf90_inq_varid "//trim(fields(var)%io_name) )

      endif  ! Clobber


      ! Set starts and counts based on levels and tiledim flag
      ! ------------------------------------------------------

      if (associated(istart)) nullify(istart)
      if (associated(icount)) nullify(icount)

      ! Change the counts to match the correct number of levels for 3D fields
      if (fields(var)%npz > 1) then
        self%ic_r3_tile(self%vindex_tile) = fields(var)%npz
        self%ic_r3_noti(self%vindex_noti) = fields(var)%npz
      endif

      if ( fields(var)%npz == 1 ) then
        if (self%conf%tile_is_a_dimension(1)) then
          istart => self%is_r2_tile; icount => self%ic_r2_tile
        else
          istart => self%is_r2_noti; icount => self%ic_r2_noti
        endif
      elseif (fields(var)%npz > 1) then
        if (self%conf%tile_is_a_dimension(1)) then
          istart => self%is_r3_tile; icount => self%ic_r3_tile
        else
          istart => self%is_r3_noti; icount => self%ic_r3_noti
        endif
      endif

      ! Whole tile array that can accomodate any of the fields
      ! ------------------------------------------------------
      if (.not.allocated(arrayg)) allocate(arrayg(1:self%npx-1,1:self%npy-1,1:maxlev))
      arrayg = 0.0_kind_real

    endif  ! io_proc

    ! Gather the tiles to the write processors
    if (self%csize > 6) then
      call self%tile_comms%gather_tile(fields(var)%npz, &
                                       fields(var)%array(self%isc:self%iec,self%jsc:self%jec,1:fields(var)%npz), &
                                       arrayg)
    else
      arrayg(self%isc:self%iec,self%jsc:self%jec,1:fields(var)%npz) = &
                            fields(var)%array(self%isc:self%iec,self%jsc:self%jec,1:fields(var)%npz)
    endif

    ! Write the field to file
    if (self%iam_io_proc) then
        call nccheck( nf90_put_var( ncid, varid, arrayg(1:self%npx-1,1:self%npy-1,1:fields(var)%npz), start = istart, &
                                    count = icount ), "nf90_put_var "//trim(fields(var)%io_name) )
    endif

  endif  ! write_field

enddo

! Deallocate locals
! -----------------
if (allocated(arrayg)) deallocate(arrayg)

end subroutine write_fields

! --------------------------------------------------------------------------------------------------

! Not really needed but prevents gnu compiler bug
subroutine dummy_final(self)
type(fv3jedi_io_cube_sphere_history), intent(inout) :: self
end subroutine dummy_final

! --------------------------------------------------------------------------------------------------

subroutine open_files(self)

! Arguments
type(fv3jedi_io_cube_sphere_history), intent(inout) :: self

! Locals
integer :: n

! Open files for reading
do n = 1, self%nfiles
  call nccheck ( nf90_open( trim(self%filenames(n)), NF90_NOWRITE, &
                 self%ncid(n)), "nf90_open "//trim(self%filenames(n)) )
enddo

end subroutine open_files

! --------------------------------------------------------------------------------------------------

subroutine create_files(self)

! Arguments
type(fv3jedi_io_cube_sphere_history), intent(inout) :: self

! Locals
integer :: n, fileopts

if (self%iam_io_proc) then

  do n = 1, self%nfiles

    if (self%conf%clobber(n)) then

      fileopts = ior(NF90_NETCDF4, NF90_MPIIO)

      call nccheck( nf90_create( trim(self%filenames(n)), fileopts, &
                                 self%ncid(n), comm = self%ocomm, info = MPI_INFO_NULL), &
                                 "nf90_create"//trim(self%filenames(n)) )

    else

      call nccheck ( nf90_open( trim(self%filenames(n)), NF90_WRITE, self%ncid(n) ), &
                     "nf90_open"//trim(self%filenames(n)) )

    endif

  enddo

endif

end subroutine create_files

! --------------------------------------------------------------------------------------------------

subroutine close_files(self)

! Arguments
type(fv3jedi_io_cube_sphere_history), intent(inout) :: self

! Locals
integer :: n

! Close the files
! ---------------
if (self%iam_io_proc) then
  do n = 1, self%nfiles
    call nccheck ( nf90_close(self%ncid(n)), "nf90_close" )
  enddo
endif

end subroutine close_files

! --------------------------------------------------------------------------------------------------

end module fv3jedi_io_cube_sphere_history_mod
