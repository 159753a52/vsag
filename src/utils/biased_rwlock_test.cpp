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

#include "biased_rwlock.h"

#include <atomic>
#include <chrono>
#include <thread>

#include "unittest.h"

namespace {

void
wait_until(const std::atomic<bool>& value) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while (not value.load(std::memory_order_acquire)) {
        REQUIRE(std::chrono::steady_clock::now() < deadline);
        std::this_thread::yield();
    }
}

}  // namespace

TEST_CASE("BiasedRwLock excludes readers while a writer is active", "[ut][BiasedRwLock]") {
    vsag::BiasedRwLock lock;
    std::atomic<bool> writer_entered{false};
    std::atomic<bool> release_writer{false};
    std::atomic<bool> reader_entered{false};

    std::thread writer([&]() {
        lock.WithWriterCriticalSection([&]() {
            writer_entered.store(true, std::memory_order_release);
            while (not release_writer.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
        });
    });
    wait_until(writer_entered);

    std::thread reader([&]() {
        const auto kind = lock.LockShared(0);
        reader_entered.store(true, std::memory_order_release);
        if (kind == vsag::BiasedRwLock::SharedLockKind::kFast) {
            lock.FastUnlockShared(0);
        } else {
            lock.UnlockShared();
        }
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    REQUIRE_FALSE(reader_entered.load(std::memory_order_acquire));
    release_writer.store(true, std::memory_order_release);
    writer.join();
    reader.join();
    REQUIRE(reader_entered.load(std::memory_order_acquire));
}

TEST_CASE("BiasedRwLock keeps the pending state across waiting writers", "[ut][BiasedRwLock]") {
    vsag::BiasedRwLock lock;
    std::atomic<bool> first_entered{false};
    std::atomic<bool> second_entered{false};
    std::atomic<bool> release_first{false};
    std::atomic<bool> release_second{false};
    std::atomic<bool> reader_entered{false};

    std::thread first_writer([&]() {
        lock.WithWriterCriticalSection([&]() {
            first_entered.store(true, std::memory_order_release);
            while (not release_first.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
        });
    });
    wait_until(first_entered);

    std::thread second_writer([&]() {
        lock.WithWriterCriticalSection([&]() {
            second_entered.store(true, std::memory_order_release);
            while (not release_second.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
        });
    });

    release_first.store(true, std::memory_order_release);
    wait_until(second_entered);

    std::thread reader([&]() {
        const auto kind = lock.LockShared(1);
        reader_entered.store(true, std::memory_order_release);
        if (kind == vsag::BiasedRwLock::SharedLockKind::kFast) {
            lock.FastUnlockShared(1);
        } else {
            lock.UnlockShared();
        }
    });

    REQUIRE_FALSE(reader_entered.load(std::memory_order_acquire));
    release_second.store(true, std::memory_order_release);
    first_writer.join();
    second_writer.join();
    reader.join();
    REQUIRE(reader_entered.load(std::memory_order_acquire));
}
