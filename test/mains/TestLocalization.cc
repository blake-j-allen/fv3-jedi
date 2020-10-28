/*
 * (C) Copyright 2017 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#include "fv3jedi/Utilities/Traits.h"
#include "oops/runs/Run.h"
#include "saber/oops/instantiateLocalizationFactory.h"
#include "test/interface/Localization.h"

int main(int argc,  char ** argv) {
  oops::Run run(argc, argv);
  saber::instantiateLocalizationFactory<fv3jedi::Traits>();
  test::Localization<fv3jedi::Traits> tests;
  return run.execute(tests);
}

