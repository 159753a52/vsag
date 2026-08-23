// Copyright 2024-present the vsag project
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <future>
#include <memory>
#include <shared_mutex>
#include <string>
#include <vector>

#include "hgraph.h"
#include "impl/allocator/safe_allocator.h"
#include "index/index_impl.h"
#include "unittest.h"

namespace vsag {

class HGraphConcurrencyTestAccessor {
public:
    static bool
    VerifyCrossOwnerReadNesting(HGraph& first, HGraph& second) {
        if (HGraph::tls_top_read_guard() != nullptr) {
            return false;
        }

        auto first_outer = first.acquire_global_read_lock();
        auto second_guard = second.acquire_global_read_lock();
        auto first_inner = first.acquire_global_read_lock();

        bool valid = first_outer.owns_underlying_lock_ and second_guard.owns_underlying_lock_ and
                     not first_inner.owns_underlying_lock_ and
                     first_outer.kind_ == first_inner.kind_ and
                     HGraph::tls_top_read_guard() == &first_inner;

        // Release out of nesting order to verify that ownership moves to the
        // remaining same-owner guard instead of dropping the underlying grant.
        first_outer.unlock();
        valid = valid and first_inner.owns_underlying_lock_;
        first_inner.unlock();
        second_guard.unlock();
        return valid and HGraph::tls_top_read_guard() == nullptr;
    }

    static std::shared_lock<std::shared_mutex>
    HoldAddLifecycle(HGraph& graph) {
        return std::shared_lock<std::shared_mutex>(graph.immutable_transition_mutex_);
    }

    static bool
    CanEnterImmutableTransition(HGraph& graph) {
        if (not graph.immutable_transition_mutex_.try_lock()) {
            return false;
        }
        graph.immutable_transition_mutex_.unlock();
        return true;
    }
};

}  // namespace vsag

namespace {

std::shared_ptr<vsag::HGraph>
MakeHGraph() {
    auto config = vsag::JsonType::Parse(R"({
        "base_quantization_type": "fp32",
        "max_degree": 8,
        "ef_construction": 32,
        "build_thread_count": 1
    })");
    vsag::IndexCommonParam common_param;
    common_param.dim_ = 2;
    common_param.metric_ = vsag::MetricType::METRIC_TYPE_L2SQR;
    common_param.data_type_ = vsag::DataTypes::DATA_TYPE_FLOAT;
    common_param.allocator_ = vsag::SafeAllocator::FactoryDefaultAllocator();
    auto index = std::make_shared<vsag::IndexImpl<vsag::HGraph>>(config, common_param);
    return std::dynamic_pointer_cast<vsag::HGraph>(index->GetInnerIndex());
}

}  // namespace

TEST_CASE("HGraph read guards preserve per-owner nesting across instances",
          "[ut][hgraph][concurrency][read_guard]") {
    auto first = MakeHGraph();
    auto second = MakeHGraph();

    REQUIRE(vsag::HGraphConcurrencyTestAccessor::VerifyCrossOwnerReadNesting(*first, *second));
}

TEST_CASE("HGraph immutable transition excludes an active Add lifecycle",
          "[ut][hgraph][concurrency][immutable]") {
    auto graph = MakeHGraph();

    auto add_lifecycle = vsag::HGraphConcurrencyTestAccessor::HoldAddLifecycle(*graph);
    auto blocked_transition = std::async(std::launch::async, [&]() {
        return vsag::HGraphConcurrencyTestAccessor::CanEnterImmutableTransition(*graph);
    });
    REQUIRE_FALSE(blocked_transition.get());
    add_lifecycle.unlock();
    REQUIRE(vsag::HGraphConcurrencyTestAccessor::CanEnterImmutableTransition(*graph));
}

TEST_CASE("HGraph Add rechecks immutable state inside its lifecycle lock",
          "[ut][hgraph][concurrency][immutable]") {
    auto graph = MakeHGraph();
    graph->SetImmutable();

    std::vector<float> vectors = {0.0F, 0.0F};
    std::vector<int64_t> ids = {1};
    auto dataset = vsag::Dataset::Make();
    dataset->NumElements(1)->Dim(2)->Ids(ids.data())->Float32Vectors(vectors.data())->Owner(false);

    try {
        graph->Add(dataset);
        FAIL("Add unexpectedly accepted an immutable HGraph");
    } catch (const vsag::VsagException& error) {
        REQUIRE(error.error_.type == vsag::ErrorType::UNSUPPORTED_INDEX_OPERATION);
    }
}
