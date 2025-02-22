/*
 * (C) Copyright 2019 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#pragma once

#include <iterator>
#include <string>

#include "eckit/geometry/Point3.h"

#include "fv3jedi/Geometry/Geometry.h"
#include "fv3jedi/GeometryIterator/GeometryIterator.interface.h"

#include "oops/util/ObjectCounter.h"
#include "oops/util/Printable.h"

namespace fv3jedi {

class Geometry;

// -----------------------------------------------------------------------------
class GeometryIterator: public util::Printable,
                        private util::ObjectCounter<GeometryIterator> {
 public:
  typedef std::forward_iterator_tag iterator_category;
  typedef eckit::geometry::Point3 value_type;
  typedef ptrdiff_t difference_type;
  typedef eckit::geometry::Point3 & reference;
  typedef eckit::geometry::Point3 * pointer;

  static const std::string classname() {return "fv3jedi::GeometryIterator";}

  GeometryIterator(const GeometryIterator &);
  explicit GeometryIterator(const Geometry & geom, const int & iindex = 1,
                            const int & jindex = 1, const int & kindex = 1);
  ~GeometryIterator();

  bool operator==(const GeometryIterator &) const;
  bool operator!=(const GeometryIterator &) const;
  eckit::geometry::Point3 operator*() const;
  // pre-increment operator
  GeometryIterator& operator++();

  double getOrography() const;
  double getNominalSurfacePressure() const;

// Utilities
  F90iter & toFortran() {return keyIter_;}
  const F90iter & toFortran() const {return keyIter_;}

 private:
  void print(std::ostream &) const;
  F90iter keyIter_;
  const  Geometry & geom_;
};

}  // namespace fv3jedi
