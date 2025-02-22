/*
 * (C) Copyright 2024 UCAR
 *
 * This software is licensed under the terms of the Apache Licence Version 2.0
 * which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.
 */

#include "fv3jedi/Utilities/Traits.h"
#include "oops/runs/Run.h"
#include "test/util/CompareStates.h"

int main(int argc,  char ** argv) {
  oops::Run run(argc, argv);
  test::CompareStates<fv3jedi::Traits> tests;
  return run.execute(tests);
}

