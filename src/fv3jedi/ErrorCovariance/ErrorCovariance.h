/*
 * (C) Copyright 2017 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#ifndef FV3JEDI_ERRORCOVARIANCE_ERRORCOVARIANCE_H_
#define FV3JEDI_ERRORCOVARIANCE_ERRORCOVARIANCE_H_

#include <ostream>
#include <string>
#include <boost/noncopyable.hpp>
#include <boost/scoped_ptr.hpp>

#include "fv3jedi/ErrorCovariance/ErrorCovariance.interface.h"

#include "fv3jedi/Geometry/Geometry.h"

#include "eckit/config/Configuration.h"
#include "oops/util/DateTime.h"
#include "oops/util/ObjectCounter.h"
#include "oops/util/Printable.h"

// Forward declarations
namespace oops {
  class Variables;
}

namespace fv3jedi {
  class Increment;
  class State;

// -----------------------------------------------------------------------------
/// Background error covariance matrix for FV3JEDI

class ErrorCovariance : public util::Printable,
                           private boost::noncopyable,
                           private util::ObjectCounter<ErrorCovariance> {
 public:
  static const std::string classname()
                                  {return "fv3jedi::ErrorCovariance";}

  ErrorCovariance(const Geometry &, const oops::Variables &,
                         const eckit::Configuration &, const State &,
                         const State &);
  ~ErrorCovariance();

  void linearize(const State &, const Geometry &);
  void multiply(const Increment &, Increment &) const;
  void inverseMultiply(const Increment &, Increment &) const;
  void randomize(Increment &) const;

 private:
  void print(std::ostream &) const;
  F90bmat keyFtnConfig_;
  boost::scoped_ptr<const Geometry> geom_;
  util::DateTime time_;
};
// -----------------------------------------------------------------------------

}  // namespace fv3jedi
#endif  // FV3JEDI_ERRORCOVARIANCE_ERRORCOVARIANCE_H_
