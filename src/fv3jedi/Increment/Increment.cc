/*
 * (C) Copyright 2017-2022 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#include <algorithm>
#include <iomanip>
#include <ios>
#include <iostream>
#include <numeric>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "atlas/field.h"
#include "atlas/functionspace.h"

#include "eckit/config/Configuration.h"
#include "eckit/exception/Exceptions.h"

#include "oops/base/GeometryData.h"
#include "oops/base/Variables.h"
#include "oops/generic/GlobalInterpolator.h"
#include "oops/util/DateTime.h"
#include "oops/util/Duration.h"
#include "oops/util/Logger.h"

#include "fv3jedi/Geometry/Geometry.h"
#include "fv3jedi/Increment/Increment.h"
#include "fv3jedi/IO/Utils/IOBase.h"
#include "fv3jedi/State/State.h"

namespace fv3jedi {

// -------------------------------------------------------------------------------------------------

Increment::Increment(const Geometry & geom, const oops::Variables & vars,
                     const util::DateTime & time)
  : geom_(geom), vars_(geom_.fieldsMetaData().getLongNameFromAnyName(vars)),
    varsJedi_(geom_.fieldsMetaData().removeInterfaceSpecificFields(vars)),
    time_(time)
{
  oops::Log::trace() << "Increment::Increment (from geom, vars and time) starting" << std::endl;
  fv3jedi_increment_create_f90(keyInc_, geom_.toFortran(), vars_, time_);
  fv3jedi_increment_zero_f90(keyInc_);
  oops::Log::trace() << "Increment::Increment (from geom, vars and time) done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
Increment::Increment(const Geometry & geom, const Increment & other, const bool ad)
  : geom_(geom), vars_(other.vars_), varsJedi_(other.varsJedi_), time_(other.time_)
{
  oops::Log::trace() << "Increment::Increment (from geom and other) starting" << std::endl;
  fv3jedi_increment_create_f90(keyInc_, geom_.toFortran(), vars_, time_);

  // If both increments have same resolution, then copy instead of interpolating
  if (geom_.isEqual(other.geom_)) {
    fv3jedi_increment_copy_f90(keyInc_, other.keyInc_);
    time_ = other.time_;
    return;
  }

  eckit::LocalConfiguration conf;
  // Use oops interpolator for consistency with State resolution change.
  conf.set("local interpolator type", "oops unstructured grid interpolator");

  atlas::FieldSet source{};
  atlas::FieldSet target{};

  if (ad) {
    const oops::GeometryData source_geom(geom_.functionSpace(),
                                         geom_.fields(),
                                         geom_.levelsAreTopDown(),
                                         geom_.getComm());
    const atlas::FunctionSpace target_fs = other.geom_.functionSpace();
    oops::GlobalInterpolator interp(conf, source_geom, target_fs, geom_.getComm());

    other.toFieldSet(target);
    interp.applyAD(source, target);
    this->fromFieldSet(source);
  } else {
    const oops::GeometryData source_geom(other.geom_.functionSpace(),
                                         other.geom_.fields(),
                                         other.geom_.levelsAreTopDown(),
                                         other.geom_.getComm());
    const atlas::FunctionSpace target_fs = geom_.functionSpace();
    oops::GlobalInterpolator interp(conf, source_geom, target_fs, geom_.getComm());

    other.toFieldSet(source);
    interp.apply(source, target);
    this->fromFieldSet(target);
  }

  // Interpolation did not act on interface fields
  this->setInterfaceFieldsOutOfDate(true);

  oops::Log::trace() << "Increment::Increment (from geom and other) done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
Increment::Increment(const Increment & other, const bool copy)
  : geom_(other.geom_), vars_(other.vars_), varsJedi_(other.varsJedi_), time_(other.time_)
{
  oops::Log::trace() << "Increment::Increment (from other and bool copy) starting" << std::endl;
  fv3jedi_increment_create_f90(keyInc_, geom_.toFortran(), vars_, time_);
  if (copy) {
    fv3jedi_increment_copy_f90(keyInc_, other.keyInc_);
  } else {
    fv3jedi_increment_zero_f90(keyInc_);
  }
  oops::Log::trace() << "Increment::Increment (from other and bool copy) done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
Increment::~Increment() {
  fv3jedi_increment_delete_f90(keyInc_);
}
// -------------------------------------------------------------------------------------------------
void Increment::diff(const State & x1, const State & x2) {
  ASSERT(this->validTime() == x1.validTime());
  ASSERT(this->validTime() == x2.validTime());
  // States should have the same variables
  ASSERT(x1.variablesIncludingInterfaceFields() == x2.variablesIncludingInterfaceFields());
  // Increment variables must be a equal to or a subset of the State variables
  // (But interface-specific vars can be in increment without being in State, hence varsJedi in LHS)
  ASSERT(varsJedi_ <= x1.variablesIncludingInterfaceFields());
  // States at increment resolution
  State x1_ir(geom_, x1);
  State x2_ir(geom_, x2);
  fv3jedi_increment_diff_states_f90(keyInc_, x1_ir.toFortran(), x2_ir.toFortran(),
                                  geom_.toFortran());
}
// -------------------------------------------------------------------------------------------------
Increment & Increment::operator=(const Increment & rhs) {
  fv3jedi_increment_copy_f90(keyInc_, rhs.keyInc_);
  time_ = rhs.time_;
  return *this;
}
// -------------------------------------------------------------------------------------------------
void Increment::updateFields(const oops::Variables & newVars) {
  const oops::Variables newLongVars = geom_.fieldsMetaData().getLongNameFromAnyName(newVars);
  vars_ = newLongVars;
  varsJedi_ = geom_.fieldsMetaData().removeInterfaceSpecificFields(newLongVars);
  fv3jedi_increment_update_fields_f90(keyInc_, geom_.toFortran(), vars_);
}
// -------------------------------------------------------------------------------------------------
Increment & Increment::operator+=(const Increment & dx) {
  ASSERT(this->validTime() == dx.validTime());
  fv3jedi_increment_self_add_f90(keyInc_, dx.keyInc_);
  return *this;
}
// -------------------------------------------------------------------------------------------------
Increment & Increment::operator-=(const Increment & dx) {
  ASSERT(this->validTime() == dx.validTime());
  fv3jedi_increment_self_sub_f90(keyInc_, dx.keyInc_);
  return *this;
}
// -------------------------------------------------------------------------------------------------
Increment & Increment::operator*=(const double & zz) {
  fv3jedi_increment_self_mul_f90(keyInc_, zz);
  return *this;
}
// -------------------------------------------------------------------------------------------------
void Increment::zero() {
  fv3jedi_increment_zero_f90(keyInc_);
}
// -------------------------------------------------------------------------------------------------
void Increment::zero(const util::DateTime & vt) {
  fv3jedi_increment_zero_f90(keyInc_);
  time_ = vt;
}
// -------------------------------------------------------------------------------------------------
void Increment::ones() {
  fv3jedi_increment_ones_f90(keyInc_);
}
// -------------------------------------------------------------------------------------------------
void Increment::axpy(const double & zz, const Increment & dx, const bool check) {
  ASSERT(!check || this->validTime() == dx.validTime());
  fv3jedi_increment_axpy_inc_f90(keyInc_, zz, dx.keyInc_);
}
// -------------------------------------------------------------------------------------------------
void Increment::accumul(const double & zz, const State & xx) {
  fv3jedi_increment_axpy_state_f90(keyInc_, zz, xx.toFortran());
}
// -------------------------------------------------------------------------------------------------
void Increment::schur_product_with(const Increment & dx) {
  fv3jedi_increment_self_schur_f90(keyInc_, dx.keyInc_);
}
// -------------------------------------------------------------------------------------------------
double Increment::dot_product_with(const Increment & other) const {
  double zz;
  fv3jedi_increment_dot_prod_f90(keyInc_, other.keyInc_, zz);
  return zz;
}
// -------------------------------------------------------------------------------------------------
void Increment::random() {
  fv3jedi_increment_random_f90(keyInc_);
}
// -------------------------------------------------------------------------------------------------
oops::LocalIncrement Increment::getLocal(const GeometryIterator & iter) const {
  int ist, iend, jst, jend, kst, kend, npz;
  fv3jedi_geom_start_end_f90(geom_.toFortran(), ist, iend, jst, jend, kst, kend, npz);

  oops::Variables fieldNames = vars_;

  std::vector<int> varlens(fieldNames.size());
  for (unsigned int ii = 0; ii < fieldNames.size(); ii++) {
     // might need to modify if non-npz variables are also used
     varlens[ii] = npz;
  }

  int lenvalues = std::accumulate(varlens.begin(), varlens.end(), 0);
  std::vector<double> values(lenvalues);

  // Get variable values
  fv3jedi_increment_getpoint_f90(keyInc_, iter.toFortran(), values[0],
                                  values.size());

  return oops::LocalIncrement(oops::Variables(fieldNames), values, varlens);
}
// -------------------------------------------------------------------------------------------------
void Increment::setLocal(const oops::LocalIncrement & values, const GeometryIterator & iter) {
  const std::vector<double> vals = values.getVals();
  fv3jedi_increment_setpoint_f90(keyInc_, iter.toFortran(), vals[0], vals.size());
}
// -------------------------------------------------------------------------------------------------
void Increment::toFieldSet(atlas::FieldSet & fset) const {
  fv3jedi_increment_to_fieldset_f90(keyInc_, geom_.toFortran(), varsJedi_, fset.get());
}
// -------------------------------------------------------------------------------------------------
void Increment::fromFieldSet(const atlas::FieldSet & fset) {
  fv3jedi_increment_from_fieldset_f90(keyInc_, geom_.toFortran(), varsJedi_, fset.get());
}
// -------------------------------------------------------------------------------------------------
void Increment::synchronizeInterfaceFields() const {
  fv3jedi_increment_synchronize_interface_fields_f90(keyInc_, geom_.toFortran());
}
// -------------------------------------------------------------------------------------------------
void Increment::setInterfaceFieldsOutOfDate(const bool outofdate) const {
  fv3jedi_increment_set_interface_fields_outofdate_f90(keyInc_, outofdate);
}
// -------------------------------------------------------------------------------------------------
void Increment::read(const eckit::Configuration & config) {
  ReadParameters_ params;
  params.deserialize(config);
  // Optionally set the datetime on read (needed for some bump applications)
  if (params.setdatetime.value() != boost::none) {
    if (*params.setdatetime.value() && params.datetime.value() != boost::none) {
      time_ = *params.datetime.value();
    }
  }
  // Create IO object
  std::unique_ptr<IOBase> io(IOFactory::create(geom_,
                                               *params.ioParametersWrapper.ioParameters.value()));
  // Perform read
  io->read(*this);
}
// -------------------------------------------------------------------------------------------------
void Increment::write(const eckit::Configuration & config) const {
  WriteParameters_ params;
  params.deserialize(config);
  // Create IO object
  std::unique_ptr<IOBase> io(IOFactory::create(geom_,
                                               *params.ioParametersWrapper.ioParameters.value()));
  // Perform write
  this->synchronizeInterfaceFields();
  io->write(*this);
}
// -------------------------------------------------------------------------------------------------
double Increment::norm() const {
  this->synchronizeInterfaceFields();
  double zz = 0.0;
  fv3jedi_increment_norm_f90(keyInc_, zz);
  return zz;
}
// -------------------------------------------------------------------------------------------------
void Increment::print(std::ostream & os) const {
  // Get the number of fields
  int numberFields;
  int cubeSize;
  fv3jedi_increment_getnfieldsncube_f90(keyInc_, numberFields, cubeSize);

  // Header
  os << std::endl
     << "--------------------------------------------------"
        "--------------------------------------------------";
  os << std::endl << "Increment print | number of fields = " << numberFields
                  << " | cube sphere face size: C" << cubeSize;

  // Print info field by field
  const int FieldNameLen = 45;
  char fieldName[FieldNameLen];
  std::vector<double> minMaxRms(3);
  for (int f = 0; f < numberFields; f++) {
    int fp1 = f+1;
    fv3jedi_increment_getminmaxrms_f90(keyInc_, fp1, FieldNameLen-1, fieldName, minMaxRms[0]);
    std::string fieldNameStr(fieldName);
    os << std::endl << std::scientific << std::showpos << fieldNameStr.substr(0, FieldNameLen-1)
                    << " | Min:" << minMaxRms[0] << " Max:" << minMaxRms[1]
                    << " RMS:" << minMaxRms[2] << std::noshowpos;
  }

  os.unsetf(std::ios_base::floatfield);

  // Footer
  os << std::endl
     << "--------------------------------------------------"
        "--------------------------------------------------";
}
// -------------------------------------------------------------------------------------------------
void Increment::dirac(const eckit::Configuration & config) {
  DiracParameters_ params;
  params.deserialize(config);
  fv3jedi_increment_dirac_f90(keyInc_, params.toConfiguration(), geom_.toFortran());
}
// -------------------------------------------------------------------------------------------------
size_t Increment::serialSize() const {
  size_t nn = 1;
  int inc_size;
  fv3jedi_increment_sizes_f90(keyInc_, inc_size);
  nn+= inc_size;  // to verify
  nn += time_.serialSize();
  return nn;
}
// -------------------------------------------------------------------------------------------------
void Increment::serialize(std::vector<double> & vect) const {
  int size_inc = this->serialSize() - 3;
  std::vector<double> v_inc(size_inc, 0);

  fv3jedi_increment_serialize_f90(keyInc_, size_inc, v_inc.data());
  vect.insert(vect.end(), v_inc.begin(), v_inc.end());

  // Serialize the date and time
  vect.push_back(-54321.98765);
  time_.serialize(vect);
}
// -------------------------------------------------------------------------------------------------
void Increment::deserialize(const std::vector<double> & vect,
                                   size_t & index) {
  fv3jedi_increment_deserialize_f90(keyInc_, vect.size(), vect.data(), index);

  ASSERT(vect.at(index) == -54321.98765);
  ++index;

  time_.deserialize(vect, index);
}
// -------------------------------------------------------------------------------------------------
}  // namespace fv3jedi
