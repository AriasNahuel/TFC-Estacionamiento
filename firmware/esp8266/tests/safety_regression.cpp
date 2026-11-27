#include "../SafetyLogic.h"

#include <cassert>
#include <iostream>
#include <string>

using TfcSafety::BarrierPosition;
using TfcSafety::FixedQueue;
using TfcSafety::RecoveryAction;
using TfcSafety::RemoteOperationState;
using TfcSafety::SensorClearTracker;

struct TestCommand {
  std::string id;
  std::string direction;
  std::string vehicleType;
};

struct TestReservationBackend {
  std::string token = "004271";
  std::string state = "available";
  bool vehiclePresent = false;
  int reservedCount = 0;

  bool begin(const std::string &direction, const std::string &providedToken,
             const std::string &action, TestCommand &command) {
    if (providedToken != token) return false;
    if (direction == "entry") {
      if (vehiclePresent || (state != "available" && state != "retained")) return false;
    } else if (direction == "exit") {
      if (!vehiclePresent || state != "parked" || (action != "retain" && action != "finish")) return false;
    } else return false;
    command = {"operation", direction, "reserved"};
    return true;
  }

  void finish(const TestCommand &command, const std::string &action = "finish") {
    if (command.direction == "entry") {
      state = "parked";
      vehiclePresent = true;
      ++reservedCount;
    } else {
      vehiclePresent = false;
      --reservedCount;
      state = action == "retain" ? "retained" : "finished";
    }
  }
};

static void testReservationRetainReentryAndFinalization() {
  TestReservationBackend backend;
  TestCommand command;
  FixedQueue<TestCommand, 6> queue;

  assert(backend.begin("entry", "004271", "finish", command));
  assert(command.vehicleType == "reserved" && command.direction == "entry");
  assert(queue.push(command));
  assert(backend.reservedCount == 0);  // pending operation does not double count
  backend.finish(command);
  assert(backend.state == "parked" && backend.vehiclePresent && backend.reservedCount == 1);
  assert(queue.pop(command) && queue.empty());

  assert(backend.begin("exit", "004271", "retain", command));
  assert(command.vehicleType == "reserved" && command.direction == "exit");
  backend.finish(command, "retain");
  assert(backend.state == "retained" && !backend.vehiclePresent && backend.reservedCount == 0);

  assert(backend.begin("entry", "004271", "finish", command));
  assert(command.vehicleType == "reserved" && command.direction == "entry");
  backend.finish(command);
  assert(backend.state == "parked" && backend.vehiclePresent && backend.reservedCount == 1);
  assert(backend.begin("exit", "004271", "finish", command));
  backend.finish(command, "finish");
  assert(backend.state == "finished" && !backend.vehiclePresent && backend.reservedCount == 0);
}

static void testIndependentSensorLatchesAndStableClear() {
  SensorClearTracker entry;
  SensorClearTracker exit;
  assert(!entry.update(true, 0, 100, 500));
  assert(!exit.update(true, 0, 100, 500));
  assert(entry.update(true, 0, 600, 500));
  assert(exit.update(true, 0, 600, 500));

  // A falling edge on the opposite lane resets only that lane's tracker.
  assert(!exit.update(false, 1, 700, 500));
  assert(entry.update(true, 0, 700, 500));
  assert(!exit.update(true, 1, 701, 500));
  assert(!exit.update(true, 1, 1200, 500));
  assert(exit.update(true, 1, 1201, 500));

  // A sensor active during an operation is never considered clear.
  assert(!entry.update(false, 1, 1300, 500));
  assert(!entry.update(true, 1, 1301, 500));
  assert(!entry.update(true, 1, 1800, 500));
  assert(entry.update(true, 1, 1801, 500));
}

static void testRecoveryWaitsForBackendAndPhysicalCertainty() {
  using TfcSafety::recoveryAction;
  assert(recoveryAction(RemoteOperationState::Active, true, true, BarrierPosition::Closed) == RecoveryAction::Wait);
  assert(recoveryAction(RemoteOperationState::Unknown, true, true, BarrierPosition::Closed) == RecoveryAction::Wait);
  assert(recoveryAction(RemoteOperationState::Terminal, false, true, BarrierPosition::Open) == RecoveryAction::Wait);
  assert(recoveryAction(RemoteOperationState::Terminal, true, false, BarrierPosition::Open) == RecoveryAction::Wait);
  assert(recoveryAction(RemoteOperationState::Terminal, true, true, BarrierPosition::Unknown) == RecoveryAction::Wait);
  assert(recoveryAction(RemoteOperationState::Terminal, true, true, BarrierPosition::Closed) == RecoveryAction::ReleaseLocalState);
  assert(recoveryAction(RemoteOperationState::Terminal, true, true, BarrierPosition::Open) == RecoveryAction::CloseBarrier);
}

static void testQueueRemovesWithoutDuplicateAndHeartbeatContinues() {
  using TfcSafety::heartbeatAllowed;
  FixedQueue<TestCommand, 3> queue;
  assert(queue.push({"entry-blocked", "entry", "reserved"}));
  assert(queue.push({"exit-ready", "exit", "reserved"}));
  assert(queue.push({"entry-next", "entry", "regular"}));
  TestCommand selected;
  assert(queue.remove(1, selected));
  assert(selected.id == "exit-ready" && queue.size() == 2);
  assert(queue.remove(0, selected) && selected.id == "entry-blocked");
  assert(queue.pop(selected) && selected.id == "entry-next" && queue.empty());
  assert(queue.empty());  // clearActiveOperation restores automatic RGB when no command remains.
  assert(queue.push({"next", "entry", "reserved"}));
  assert(!queue.empty());
  assert(queue.pop(selected));
  assert(!heartbeatAllowed(false, true, false, false, false));
  assert(!heartbeatAllowed(true, false, false, false, false));
  assert(!heartbeatAllowed(true, true, true, false, false));
  assert(!heartbeatAllowed(true, true, false, true, false));
  assert(!heartbeatAllowed(true, true, false, false, true));
  assert(heartbeatAllowed(true, true, false, false, false));
}

int main() {
  testReservationRetainReentryAndFinalization();
  testIndependentSensorLatchesAndStableClear();
  testRecoveryWaitsForBackendAndPhysicalCertainty();
  testQueueRemovesWithoutDuplicateAndHeartbeatContinues();
  std::cout << "4 firmware safety regression groups passed\\n";
}
