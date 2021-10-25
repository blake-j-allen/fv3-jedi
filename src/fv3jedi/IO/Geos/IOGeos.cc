/*
 * (C) Copyright 2021 UCAR.
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#include <ostream>
#include <string>

#include "eckit/config/Configuration.h"

#include "oops/util/Logger.h"
#include "oops/util/Timer.h"

#include "fv3jedi/Geometry/Geometry.h"
#include "fv3jedi/Increment/Increment.h"
#include "fv3jedi/IO/Geos/IOGeos.h"
#include "fv3jedi/State/State.h"

namespace fv3jedi {
// -------------------------------------------------------------------------------------------------
static IOMaker<IOGeos> makerIOGeos_("geos");
// -------------------------------------------------------------------------------------------------
IOGeos::IOGeos(const eckit::Configuration & conf, const Geometry & geom) : IOBase(conf, geom) {
  util::Timer timer(classname(), "IOGeos");
  oops::Log::trace() << classname() << " constructor starting" << std::endl;
  fv3jedi_io_geos_create_f90(objectKeyForFortran_, conf, geom.toFortran());
  oops::Log::trace() << classname() << " constructor done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
IOGeos::~IOGeos() {
  util::Timer timer(classname(), "~IOGeos");
  oops::Log::trace() << classname() << " destructor starting" << std::endl;
  fv3jedi_io_geos_delete_f90(objectKeyForFortran_);
  oops::Log::trace() << classname() << " destructor done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
void IOGeos::read(State & x) const {
  util::Timer timer(classname(), "read state");
  oops::Log::trace() << classname() << " read state starting" << std::endl;
  fv3jedi_io_geos_read_state_f90(objectKeyForFortran_, x.toFortran(), &x.time());
  oops::Log::trace() << classname() << " read state done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
void IOGeos::read(Increment & dx) const {
  util::Timer timer(classname(), "read increment");
  oops::Log::trace() << classname() << " read increment starting" << std::endl;
  fv3jedi_io_geos_read_increment_f90(objectKeyForFortran_, dx.toFortran(), &dx.time());
  oops::Log::trace() << classname() << " read increment done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
void IOGeos::write(const State & x) const {
  util::Timer timer(classname(), "write state");
  oops::Log::trace() << classname() << " write state starting" << std::endl;
  fv3jedi_io_geos_write_state_f90(objectKeyForFortran_, x.toFortran(), &x.time());
  oops::Log::trace() << classname() << " write state done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
void IOGeos::write(const Increment & dx) const {
  util::Timer timer(classname(), "write increment");
  oops::Log::trace() << classname() << " write increment starting" << std::endl;
  fv3jedi_io_geos_write_increment_f90(objectKeyForFortran_, dx.toFortran(), &dx.time());
  oops::Log::trace() << classname() << " write increment done" << std::endl;
}
// -------------------------------------------------------------------------------------------------
void IOGeos::print(std::ostream & os) const {
  os << classname() << " IO for GEOS model";
}
// -------------------------------------------------------------------------------------------------
}  // namespace fv3jedi
