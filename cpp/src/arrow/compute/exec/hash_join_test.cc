// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include <gmock/gmock-matchers.h>

#include "arrow/api.h"
#include "arrow/compute/exec/test_util.h"
#include "arrow/testing/gtest_util.h"
#include "arrow/testing/matchers.h"

using testing::UnorderedElementsAreArray;

namespace arrow {
namespace compute {

void GenerateBatchesFromString(const std::shared_ptr<Schema>& schema,
                               const std::vector<util::string_view>& json_strings,
                               BatchesWithSchema* out_batches) {
  std::vector<ValueDescr> descrs;
  for (auto&& field : schema->fields()) {
    descrs.emplace_back(field->type());
  }

  for (auto&& s : json_strings) {
    out_batches->batches.push_back(ExecBatchFromJSON(descrs, s));
  }

  out_batches->schema = schema;
}

TEST(HashJoin, LeftSemi) {
  auto l_schema = schema({field("l_i32", int32()), field("l_str", utf8())});
  auto r_schema = schema({field("r_str", utf8()), field("r_i32", int32())});
  BatchesWithSchema l_batches, r_batches, exp_batches;

  GenerateBatchesFromString(l_schema,
                            {R"([[0,"d"], [1,"b"]])", R"([[2,"d"], [3,"a"], [4,"a"]])",
                             R"([[5,"b"], [6,"c"], [7,"e"], [8,"e"]])"},
                            &l_batches);

  GenerateBatchesFromString(
      r_schema,
      {R"([["f", 0], ["b", 1], ["b", 2]])", R"([["c", 3], ["g", 4]])", R"([["e", 5]])"},
      &r_batches);

  SCOPED_TRACE("serial");

  ASSERT_OK_AND_ASSIGN(auto plan, ExecPlan::Make());

  ASSERT_OK_AND_ASSIGN(auto l_source,
                       MakeTestSourceNode(plan.get(), "l_source", l_batches,
                                          /*parallel=*/false,
                                          /*slow=*/false));
  ASSERT_OK_AND_ASSIGN(auto r_source,
                       MakeTestSourceNode(plan.get(), "r_source", r_batches,
                                          /*parallel=*/false,
                                          /*slow=*/false));

  ASSERT_OK_AND_ASSIGN(
      auto semi_join,
      MakeHashJoinNode(JoinType::LEFT_SEMI, l_source, r_source, "l_semi_join",
                       /*left_keys=*/{"l_str"}, /*right_keys=*/{"r_str"}));
  auto sink_gen = MakeSinkNode(semi_join, "sink");

  GenerateBatchesFromString(
      l_schema, {R"([[1,"b"]])", R"([])", R"([[5,"b"], [6,"c"], [7,"e"], [8,"e"]])"},
      &exp_batches);

  ASSERT_THAT(StartAndCollect(plan.get(), sink_gen),
              Finishes(ResultWith(UnorderedElementsAreArray(exp_batches.batches))));
}

}  // namespace compute
}  // namespace arrow