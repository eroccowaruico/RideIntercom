"""Ownership-scoped cleanup for local test hosts; no application-name pkill."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import time


@contextmanager
def exclusive_run(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as lock:
        # Do not unlink a lock file: a waiter could otherwise lock a new inode.
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def process_listing():
    return subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=10)


def matching_processes(executable):
    expected = Path(executable).resolve()
    result = []
    for line in process_listing().splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and Path(fields[1]).resolve() == expected:
            result.append(int(fields[0]))
    return result


def stop_executable(executable):
    owned = matching_processes(executable)
    for pid in owned:
        # Recheck immediately before signaling, including the escalation below.
        if pid in matching_processes(executable):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 3
    while True:
        remaining = set(owned).intersection(matching_processes(executable))
        if not remaining:
            return owned
        if time.monotonic() >= deadline:
            break
        time.sleep(0.05)
    for pid in remaining:
        if pid in matching_processes(executable):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 2
    while set(owned).intersection(matching_processes(executable)):
        if time.monotonic() >= deadline:
            raise RuntimeError('Owned test host did not terminate')
        time.sleep(0.05)
    return owned


def simulator_devices():
    data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '-j'], text=True, timeout=60))
    return [device for devices in data['devices'].values() for device in devices]


class SimulatorLease:
    """Journal before creation, so interruption between create/UUID is recoverable.

    A reusable lease retains exactly one powered-off device. Ephemeral leases
    delete it. Only the recorded full name and (when known) UUID are eligible.
    """
    def __init__(self, runner, journal):
        self.runner = runner
        self.journal = Path(journal)
        self.state = json.loads(self.journal.read_text()) if self.journal.exists() else {}

    def save(self):
        self.journal.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.journal.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.state, indent=2) + '\n')
        temporary.replace(self.journal)

    def reserve(self, name, reusable=False):
        self.state = dict(name=name, reusable=reusable)
        self.save()

    def identify(self, device_id):
        self.state['udid'] = device_id
        self.save()

    def host(self, executable):
        self.state['executable'] = str(Path(executable).resolve())
        self.save()

    def owned_devices(self):
        return [d for d in simulator_devices() if d['name'] == self.state.get('name')
                and (not self.state.get('udid') or d['udid'] == self.state['udid'])]

    def cleanup(self, prefix):
        success = True
        if not self.state:
            return True
        if self.state.get('executable'):
            started = time.monotonic()
            try:
                stopped = stop_executable(self.state['executable'])
                self.runner.record(prefix + '-host', [], 'passed', 0, started, f'Terminated owned PIDs: {stopped}')
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                self.runner.record(prefix + '-host', [], 'failed', 1, started, str(error))
                success = False
        try:
            for index, device in enumerate(self.owned_devices()):
                if device['state'] != 'Shutdown':
                    result = self.runner.run(f'{prefix}-shutdown-{index}', ['xcrun', 'simctl', 'shutdown', device['udid']], timeout=60)
                    success = result and success
                if not self.state.get('reusable'):
                    result = self.runner.run(f'{prefix}-delete-{index}', ['xcrun', 'simctl', 'delete', device['udid']], timeout=60)
                    success = result and success
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.runner.record(prefix + '-simulator', [], 'failed', 1, time.monotonic(), str(error))
            success = False
        if success and not self.state.get('reusable'):
            self.journal.unlink(missing_ok=True)
            self.state = {}
        return success
