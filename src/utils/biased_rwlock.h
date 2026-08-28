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

#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <shared_mutex>
#include <thread>

namespace vsag {

// Reader-biased read/write indicator built from two primitives:
//
//   fast path (readers): one seq_cst fetch_add on a per-thread padded slot,
//   then one seq_cst load of pending_writer_count_. Readers hold no shared cache
//   line, so N concurrent readers never invalidate each other -- unlike a
//   pthread rwlock whose reader count sits on one hot line.
//
//   slow path: when a writer is pending, readers fall back to an underlying
//   std::shared_mutex, preserving classic exclusion semantics.
//
//   writers: mark a writer as pending, serialize on the same std::shared_mutex
//   (unique), drain every reader slot, run the critical section, then clear the
//   pending count. In-flight fast-path readers finish without touching any
//   lock, so the drain is bounded by one search duration and cannot deadlock.
//
// Correctness of the handoff uses the seq_cst total order: a reader that
// observed pending_writer_count_ == 0 ordered its slot increment before the writer's
// increment in that order, so the writer's subsequent scan must observe the
// nonzero slot and wait for it.
class BiasedRwLock {
public:
    static constexpr uint32_t kReaderSlots = 128;

    enum class SharedLockKind { kFast, kSlow };

    BiasedRwLock() = default;

    BiasedRwLock(const BiasedRwLock&) = delete;
    BiasedRwLock&
    operator=(const BiasedRwLock&) = delete;

    [[nodiscard]] SharedLockKind
    LockShared(uint32_t reader_slot_index) {
        auto& slot = reader_slots_[reader_slot_index].count;
        if (pending_writer_count_.load(std::memory_order_relaxed) == 0) {
            slot.fetch_add(1, std::memory_order_seq_cst);
            if (pending_writer_count_.load(std::memory_order_seq_cst) == 0) {
                return SharedLockKind::kFast;
            }
            slot.fetch_sub(1, std::memory_order_release);
        }
        mutex_.lock_shared();
        return SharedLockKind::kSlow;
    }

    void
    FastUnlockShared(uint32_t reader_slot_index) {
        reader_slots_[reader_slot_index].count.fetch_sub(1, std::memory_order_release);
    }

    void
    UnlockShared() {
        mutex_.unlock_shared();
    }

    // Exclusive access. Caller must hold NO fast-path slot on this lock
    // (release it first), otherwise the drain below would spin forever.
    template <typename CriticalSection>
    void
    WithWriterCriticalSection(CriticalSection&& critical) {
        PendingWriterLockGuard pending_writer_lock(pending_writer_count_, mutex_);
        for (auto& slot : reader_slots_) {
            while (slot.count.load(std::memory_order_seq_cst) != 0) {
                std::this_thread::yield();
            }
        }
        critical();
    }

private:
    class PendingWriterLockGuard {
    public:
        PendingWriterLockGuard(std::atomic<uint32_t>& pending_writer_count,
                               std::shared_mutex& mutex)
            : pending_writer_count_(pending_writer_count) {
            pending_writer_count_.fetch_add(1, std::memory_order_seq_cst);
            try {
                exclusive_ = std::unique_lock<std::shared_mutex>(mutex);
            } catch (...) {
                pending_writer_count_.fetch_sub(1, std::memory_order_seq_cst);
                throw;
            }
        }

        ~PendingWriterLockGuard() {
            // Keep the pending count nonzero until the exclusive lock is released. A
            // count (rather than a bool) also prevents one writer from clearing the
            // flag while another writer is already waiting on the mutex.
            if (exclusive_.owns_lock()) {
                exclusive_.unlock();
            }
            pending_writer_count_.fetch_sub(1, std::memory_order_seq_cst);
        }

        PendingWriterLockGuard(const PendingWriterLockGuard&) = delete;
        PendingWriterLockGuard&
        operator=(const PendingWriterLockGuard&) = delete;

    private:
        std::atomic<uint32_t>& pending_writer_count_;
        std::unique_lock<std::shared_mutex> exclusive_;
    };

    struct alignas(64) ReaderSlot {
        std::atomic<uint32_t> count{0};
    };

    std::shared_mutex mutex_;
    ReaderSlot reader_slots_[kReaderSlots];
    std::atomic<uint32_t> pending_writer_count_{0};
};

}  // namespace vsag
