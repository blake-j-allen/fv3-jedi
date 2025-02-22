! (C) Copyright 2018-2019 UCAR
!
! This software is licensed under the terms of the Apache Licence Version 2.0
! which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.

module pressure_vt_mod

use fv3jedi_constants_mod, only: constant
use fv3jedi_geom_mod, only: fv3jedi_geom, pedges2pmidlayer
use fv3jedi_kinds_mod, only: kind_real

implicit none
private

public delp_to_pe_p_logp
public ps_to_delp
public ps_to_delp_tl
public ps_to_delp_ad
public tropprs
public tropprs_th

contains

!----------------------------------------------------------------------------
! Pressure thickness to pressure (edge), pressure (mid) and log p (mid) -----
!----------------------------------------------------------------------------

subroutine delp_to_pe_p_logp(geom,delp,pe,p,logp,logpe,pkz)

 type(fv3jedi_geom)  , intent(in ) :: geom !Geometry for the model
 real(kind=kind_real), intent(in ) :: delp(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Pressure thickness
 real(kind=kind_real), intent(out) ::   pe(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz+1) !Pressure edge/interface
 real(kind=kind_real), intent(out) ::    p(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Pressure mid point
 real(kind=kind_real), optional, intent(out) :: logp(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)    !Log of pressure mid point
 real(kind=kind_real), optional, intent(out) :: logpe(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz+1) !Log of pressure edge
 real(kind=kind_real), optional, intent(out) :: pkz(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)    !Log of pressure mid point

 !Locals
 integer :: isc,iec,jsc,jec,i,j,k
 real(kind=kind_real) :: peln(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz+1)
 real(kind=kind_real) ::   pk(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz+1)
 real(kind=kind_real) :: kappa

 isc = geom%isc
 iec = geom%iec
 jsc = geom%jsc
 jec = geom%jec

 kappa = constant('kappa')

 !Pressure at layer edge
 pe(isc:iec,jsc:jec,1) = geom%ptop
 do k = 2,geom%npz+1
   pe(isc:iec,jsc:jec,k) = pe(isc:iec,jsc:jec,k-1) + delp(isc:iec,jsc:jec,k-1)
 enddo

 !Midpoint pressure
 do i = isc,iec
   do j = jsc,jec
       call pedges2pmidlayer(geom%npz,'Philips',pe(i,j,:),kappa,p(i,j,:))
   enddo
 enddo

 if (present(logp)) then
   !Log pressure
   logp(isc:iec,jsc:jec,:) = log(p(isc:iec,jsc:jec,:))
   logpe(isc:iec,jsc:jec,:) = log(pe(isc:iec,jsc:jec,:))
 endif

 if (present(pkz)) then
  peln = log(pe)
  pk = exp(kappa*peln)
  do k=1,geom%npz
    pkz(:,:,k) = (pk(:,:,k+1)-pk(:,:,k)) / (kappa*(peln(:,:,k+1)-peln(:,:,k)))
  enddo
endif

end subroutine delp_to_pe_p_logp

!----------------------------------------------------------------------------

subroutine ps_to_delp(geom,ps,delp)

 type(fv3jedi_geom)  , intent(in   ) :: geom !Geometry for the model
 real(kind=kind_real), intent(in   ) ::   ps(geom%isc:geom%iec,geom%jsc:geom%jec           )   !Surface pressure
 real(kind=kind_real), intent(inout) :: delp(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Pressure thickness

 integer :: isc,iec,jsc,jec,i,j,k

 isc = geom%isc
 iec = geom%iec
 jsc = geom%jsc
 jec = geom%jec

 do k = 1,geom%npz
   do j = jsc,jec
     do i = isc,iec
       delp(i,j,k) = geom%ak(k+1) + geom%bk(k+1)*ps(i,j) - (geom%ak(k) + geom%bk(k)*ps(i,j))
     enddo
   enddo
 enddo

endsubroutine ps_to_delp

subroutine ps_to_delp_tl(geom,ps_tl,delp_tl)

 type(fv3jedi_geom)  , intent(in   ) :: geom !Geometry for the model
 real(kind=kind_real), intent(in   ) ::   ps_tl(geom%isc:geom%iec,geom%jsc:geom%jec           )   !Surface pressure
 real(kind=kind_real), intent(inout) :: delp_tl(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Pressure thickness

 integer :: isc,iec,jsc,jec,i,j,k

 isc = geom%isc
 iec = geom%iec
 jsc = geom%jsc
 jec = geom%jec

 delp_tl = 0.0_kind_real
 do k = 1,geom%npz
   do j = jsc,jec
     do i = isc,iec
       delp_tl(i,j,k) = geom%bk(k+1)*ps_tl(i,j) - geom%bk(k)*ps_tl(i,j)
     enddo
   enddo
 enddo

endsubroutine ps_to_delp_tl

subroutine ps_to_delp_ad(geom,ps_ad,delp_ad)

 type(fv3jedi_geom)  , intent(in   ) :: geom !Geometry for the model
 real(kind=kind_real), intent(inout) ::   ps_ad(geom%isc:geom%iec,geom%jsc:geom%jec           )   !Surface pressure
 real(kind=kind_real), intent(inout) :: delp_ad(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Pressure thickness

 integer :: isc,iec,jsc,jec,i,j,k

 isc = geom%isc
 iec = geom%iec
 jsc = geom%jsc
 jec = geom%jec

 ps_ad = 0.0_kind_real

 do k = geom%npz,1,-1
   do j = jec,jsc,-1
     do i = iec,isc,-1
       ps_ad(i,j) = ps_ad(i,j) + (geom%bk(k+1) - geom%bk(k))*delp_ad(i,j,k)
     enddo
   enddo
 enddo

endsubroutine ps_to_delp_ad

! --------------------------------------------------------------------------------------------------
! Locate tropopause using potential vorticity and ozone

subroutine tropprs(geom, ps, prs, tv, o3, vort, tprs)

 type(fv3jedi_geom)  , intent(in   ) :: geom
 real(kind=kind_real), intent(in   ) ::   ps(geom%isc:geom%iec,geom%jsc:geom%jec,1         )   !Surface pressure [Pa]
 real(kind=kind_real), intent(in   ) ::  prs(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Pressure, midpoint [Pa]
 real(kind=kind_real), intent(in   ) ::   tv(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Virtual temperature [K]
 real(kind=kind_real), intent(in   ) ::   o3(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Ozone mixing ratio [ppmv]
 real(kind=kind_real), intent(in   ) :: vort(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Vorticity [1/s]
 real(kind=kind_real), intent(inout) :: tprs(geom%isc:geom%iec,geom%jsc:geom%jec,1         )   !Tropopause pressure [Pa]

 ! Local
 integer :: isc,iec,jsc,jec
 integer :: i,j,k
 integer :: npz
 integer :: itrop_k
 integer :: ifound_pv, ifound_oz
 integer :: itrp_pv, itrp_oz

 real(kind=kind_real), parameter :: r1e5 = 1.0e5
 real(kind=kind_real), parameter :: r2em6 = 2.0e-6
 real(kind=kind_real), parameter :: r3em7 = 3.0e-7
 real(kind=kind_real) :: pm1, pp1, thetam1, thetap1, pv
 real(kind=kind_real) :: psi
 real(kind=kind_real) :: prsl(geom%npz), pvort(geom%npz)
 real(kind=kind_real) :: o3mr(geom%npz)
 real(kind=kind_real) :: lat, wgt
 real(kind=kind_real) :: rad2deg, constoz, kappa, grav

 ! Domain
 isc = geom%isc
 iec = geom%iec
 jsc = geom%jsc
 jec = geom%jec
 npz = geom%npz

 ! Constants
 rad2deg = constant('rad2deg')
 constoz = constant('constoz')
 kappa = constant('kappa')
 grav = constant('grav')
 ! Loop through locations
 do j = jsc, jec
   do i = isc, iec

     ! Convert latitude from radian to degree
     lat = geom%grid_lat(i,j) * rad2deg

     do k = 1, npz
       prsl(k) = prs(i,j,k)  ! [Pa]
     enddo
     psi = 1.0 / ps(i,j,1)

     ! Convert O3 unit from ppmv to mixing ratio [kg/kg]
     do k = 1, npz
       o3mr(k) = o3(i,j,k) / constoz
     enddo

     ! Compute potential vortivity (pv) at midpoint pressure
     ! Work from model surface to top
     do k =  2, npz-1
       pm1 = prsl(k+1)
       pp1 = prsl(k-1)
       thetam1 = tv(i,j,k+1) * (r1e5 / pm1)**kappa
       thetap1 = tv(i,j,k-1) * (r1e5 / pp1)**kappa
       pv = grav * vort(i,j,k) * (thetam1 - thetap1) / (pm1 - pp1)
       pvort(k) = abs(pv)
     enddo
     pvort(1) = pvort(2)
     pvort(npz) = pvort(npz-1)

     ! Locate tropopause using vorticity and ozone
     ! Search upward (decressing pressure) for tropopause above sigma 0.7
     ifound_pv = 0; itrp_pv = 1 
     ifound_oz = 0; itrp_oz = 1 
     do k = npz-1, 1, -1 
       if (prsl(k) * psi < 0.7) then  ! sigma level < 0.7
         ! Tropopause at level where pv > 2e-6
         if (pvort(k) > r2em6 .and. ifound_pv == 0) then
           ifound_pv = 1
           itrp_pv = k
         endif
         !Tropopause at level where o3mr > 3e-7
         if (o3mr(k) > r3em7 .and. ifound_oz == 0) then
           ifound_oz = 1
           itrp_oz = k
         endif
       endif
     enddo

     ! Merge pv and o3 tropopause levels between 20 and 40 degree latitudes
     wgt = 0.0
     lat =abs(lat)
     if (lat >= 40.0) then
       itrop_k = itrp_pv
     elseif (lat >=20.0) then
       wgt = (lat - 20.0) / 20.0
       itrop_k = wgt * itrp_pv + (1.0 - wgt) * itrp_oz
     else ! lat
       itrop_k = itrp_oz
     endif
     itrop_k = max(1, min(itrop_k, npz))
     tprs(i,j,1) = prsl(itrop_k)

     ! The tropopause pressures [Pa] are used for the following two things in UFO
     ! (1) deflate the moisture sensitivity vectors for satellite radiance data
     ! (2) cloud detection in IR quality control
     ! Bounds are applied on the tropopause pressure to make sure we are deflating
     ! at the very minimum above the 150 hPa and no wherer below 350 hPa

     tprs(i,j,1) = max(15000.0, min(35000.0, tprs(i,j,1)))

   enddo
 enddo

end subroutine tropprs

! --------------------------------------------------------------------------------------------------

!..Find tropopause height based on delta-Theta / delta-Z. The 10/1500 ratio
!.. approximates a vertical line on typical SkewT chart near typical (mid-latitude)
!.. tropopause height.  Since messy data could give us a false signal of such a
!.. transition, do the check over at least 35 mb delta-pres, not just a level-to-level
!.. check.  This method has potential failure in arctic-like conditions with extremely
!.. low tropopause height, as would any other diagnostic, so ensure resulting k_tropo
!.. level is above 700hPa.

subroutine tropprs_th(geom, p, z, t, tprs)

type(fv3jedi_geom)  , intent(in   ) :: geom
real(kind=kind_real), intent(in   ) ::    p(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Pressure, midpoint [Pa]
real(kind=kind_real), intent(in   ) ::    t(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Temperature [K]
real(kind=kind_real), intent(in   ) ::    z(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)   !Height/altitude [m]
real(kind=kind_real), intent(inout) :: tprs(geom%isc:geom%iec,geom%jsc:geom%jec,1         )   !Tropopause pressure [Pa]

! Local
integer :: isc,iec,jsc,jec, i, j, k
integer :: k1, k2, k_p50, k_p150, k_tropo, npz
real(kind=kind_real) :: p2(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)
real(kind=kind_real) :: z2(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)
real(kind=kind_real) :: t2(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)
real(kind=kind_real) :: theta(geom%isc:geom%iec,geom%jsc:geom%jec,1:geom%npz)

! Domain
isc = geom%isc
iec = geom%iec
jsc = geom%jsc
jec = geom%jec
npz = geom%npz

! Flip to index increasing upwards
do k = 1, npz
  do j = jsc, jec
    do i = isc, iec
      t2(i,j,k) = t(i,j,npz-k+1)
      p2(i,j,k) = p(i,j,npz-k+1)
      z2(i,j,k) = z(i,j,npz-k+1)
    enddo
  enddo
enddo

! Compute tropopause pressure
do j = jsc, jec
  do i = isc, iec
    k_p150 = 0
    k_p50 = 0
    do k = npz, 1, -1
      theta(i,j,k) = t2(i,j,k)*((100000.0/p2(i,j,k))**(287.04/1004.))
      if (p2(i,j,k) .gt. 4999.0  .and. k_p50  .eq. 0) k_p50  = k
      if (p2(i,j,k) .gt. 14999.0 .and. k_p150 .eq. 0) k_p150 = k
    enddo
    if ( (k_p50-k_p150) .lt. 3) k_p150 = k_p50-3
    do k = k_p150-2, 1, -1
      k1 = k
      k2 = k1+2
      do while (k1.gt.1 .and. (p2(i,j,k1)-p2(i,j,k2)).lt.3500.0 .and. p2(i,j,k1).lt.70000.)
        k1 = k1-1
      enddo
      if ( ((theta(i,j,k2)-theta(i,j,k1))/(z2(i,j,k2)-z2(i,j,k1))) .lt. 10./1500.) exit
    enddo
    k_tropo = max(3, min(nint(0.5*(k1+k2+1)), k_p50-1))
    tprs(i,j,1) = p2(i,j,k_tropo)
  enddo
enddo

end subroutine tropprs_th

! --------------------------------------------------------------------------------------------------

end module pressure_vt_mod
