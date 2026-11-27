#pragma once

#include <stddef.h>
#include <stdint.h>

namespace TfcSafety {

template <typename T, size_t Capacity>
class FixedQueue {
  static_assert(Capacity > 0, "Capacity must be greater than zero");

 public:
  bool push(const T &value) {
    if (size_ >= Capacity) return false;
    items_[(head_ + size_) % Capacity] = value;
    ++size_;
    return true;
  }

  bool peek(size_t offset, T &value) const {
    if (offset >= size_) return false;
    value = items_[(head_ + offset) % Capacity];
    return true;
  }

  bool remove(size_t offset, T &value) {
    if (!peek(offset, value)) return false;
    for (size_t i = offset; i + 1 < size_; ++i)
      items_[(head_ + i) % Capacity] = items_[(head_ + i + 1) % Capacity];
    items_[(head_ + size_ - 1) % Capacity] = T{};
    --size_;
    if (size_ == 0) head_ = 0;
    return true;
  }

  bool pop(T &value) { return remove(0, value); }
  size_t size() const { return size_; }
  bool empty() const { return size_ == 0; }
  bool full() const { return size_ == Capacity; }

 private:
  T items_[Capacity]{};
  size_t head_ = 0;
  size_t size_ = 0;
};

struct SensorClearTracker {
  uint16_t observedEdgeGeneration = 0;
  uint32_t highSince = 0;
  bool initialized = false;
  bool trackingHigh = false;

  bool update(bool pinHigh, uint16_t edgeGeneration, uint32_t now, uint32_t requiredMs) {
    if (!initialized || edgeGeneration != observedEdgeGeneration) {
      initialized = true;
      observedEdgeGeneration = edgeGeneration;
      trackingHigh = false;
    }
    if (!pinHigh) {
      trackingHigh = false;
      return false;
    }
    if (!trackingHigh) {
      highSince = now;
      trackingHigh = true;
    }
    return static_cast<uint32_t>(now - highSince) >= requiredMs;
  }
};

enum class RemoteOperationState : uint8_t { Unknown, Active, Terminal };
enum class BarrierPosition : uint8_t { Unknown, Closed, Open };
enum class RecoveryAction : uint8_t { Wait, CloseBarrier, ReleaseLocalState };

constexpr RecoveryAction recoveryAction(RemoteOperationState remote,
                                        bool sensorClearStable,
                                        bool actuatorReady,
                                        BarrierPosition position) {
  if (remote != RemoteOperationState::Terminal || !sensorClearStable || !actuatorReady)
    return RecoveryAction::Wait;
  if (position == BarrierPosition::Closed) return RecoveryAction::ReleaseLocalState;
  if (position == BarrierPosition::Open) return RecoveryAction::CloseBarrier;
  return RecoveryAction::Wait;
}

constexpr bool heartbeatAllowed(bool wifiConnected, bool clockValid,
                                bool diagnostics, bool wifiScan,
                                bool servoMoving) {
  return wifiConnected && clockValid && !diagnostics && !wifiScan && !servoMoving;
}

}  // namespace TfcSafety
