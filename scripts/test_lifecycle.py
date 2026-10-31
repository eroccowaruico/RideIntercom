"""Ownership-scoped cleanup for local test hosts; no application-name pkill."""
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import time
import uuid


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


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    ppid: int
    uid: int
    started: float
    command: str
    state: str

    def same_process(self, other, *, check_command=True):
        return (other is not None and (self.pid, self.uid, self.started) ==
                (other.pid, other.uid, other.started) and
                (not check_command or self.command == other.command))


def process_snapshot():
    # Keep command lines only in memory for identity checks, never in evidence.
    output = subprocess.check_output(
        ['ps', '-ww', '-axo', 'pid=,ppid=,uid=,stat=,lstart=,command='],
        text=True, timeout=10, env={**os.environ, 'LC_ALL': 'C'})
    result = {}
    for line in output.splitlines():
        fields = line.split(None, 9)
        if len(fields) != 10:
            continue
        started = time.mktime(time.strptime(' '.join(fields[4:9]), '%a %b %d %H:%M:%S %Y'))
        info = ProcessIdentity(int(fields[0]), int(fields[1]), int(fields[2]),
                               started, fields[9], fields[3])
        result[info.pid] = info
    return result


def owned_process_tree(original):
    snapshot = process_snapshot()
    root = snapshot.get(original.pid) if original else None
    # Commands may exec while running; birth time and UID still identify the root.
    if root is None or not original.same_process(root, check_command=False):
        return []
    owned = [root]
    seen = {root.pid}
    for parent in owned:
        for child in snapshot.values():
            if (child.pid not in seen and child.ppid == parent.pid and
                    child.uid == root.uid and child.started >= parent.started):
                owned.append(child)
                seen.add(child.pid)
    return owned


def live_owned_process(original, snapshot):
    current = snapshot.get(original.pid)
    return original.same_process(current) and not current.state.startswith('Z')


def signal_owned_process(original, signum):
    # PPID can change after the parent exits. Never replace the captured identity
    # with a new occupant of that PID, even during TERM -> KILL escalation.
    if live_owned_process(original, process_snapshot()):
        try:
            os.kill(original.pid, signum)
        except ProcessLookupError:
            pass


def stop_process_tree(process, original):
    # Capture descendants before terminating their parent. A test executable may
    # have its own session/PGID, so killpg alone cannot reclaim it.
    owned = owned_process_tree(original)
    if not owned and process.poll() is None:
        raise RuntimeError('Cannot establish command process ownership')
    for signum in (signal.SIGTERM, signal.SIGKILL):
        for info in reversed(owned):
            signal_owned_process(info, signum)
        deadline = time.monotonic() + 2
        while True:
            process.poll()  # Reap our direct child; orphan zombies are not running.
            snapshot = process_snapshot()
            remaining = [info for info in owned if live_owned_process(info, snapshot)]
            if not remaining:
                process.wait(timeout=2)
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(0.05)
    raise RuntimeError('Owned command processes did not terminate: ' +
                       ', '.join(str(info.pid) for info in remaining))


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
    return [dict(device, runtime=runtime) for runtime, devices in data['devices'].items() for device in devices]


def simulator_resource_root():
    # Shared across worktrees and both validation entry points.
    return Path('/tmp') / f'RideIntercom-AudioE2E-{os.getuid()}'


class SimulatorLease:
    """Journal before creation, so interruption between create/UUID is recoverable.

    A reusable lease retains exactly one powered-off device. Ephemeral leases
    delete it. Only the recorded full name and (when known) UUID are eligible.
    """
    def __init__(self, runner, journal):
        self.runner = runner
        self.journal = Path(journal)
        self.state = json.loads(self.journal.read_text()) if self.journal.exists() else {}
        self.acquired = False

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

    def prepare(self, runtime, device_type, reusable=True, delete_all=False):
        """Recover lost journals by inspecting the reserved test-device names.

        Caller holds the shared run lock through final cleanup. Never adopt or
        delete a booted device: it may be in manual use outside that lock.
        """
        devices = simulator_devices()
        (self.runner.out / 'simulator-inventory.json').write_text(json.dumps(devices, indent=2) + '\n')
        managed = [d for d in devices if re.fullmatch(
            r'RideIntercom (?:Audio E2E [0-9a-f]{8}|Validation .+|Recovery Tests)', d['name'])]
        if any(d['state'] != 'Shutdown' for d in managed):
            raise RuntimeError('Managed simulator is in use; stop its owner before retrying')
        self.acquired = True
        if not self.cleanup_host('simulator-previous'):
            raise RuntimeError('Previous owned test host could not be stopped')
        candidates = [d for d in managed if d.get('isAvailable') and d.get('runtime') == runtime
                      and d.get('deviceTypeIdentifier') == device_type] if not delete_all else []
        selected = max(candidates, key=lambda d: (d['udid'] == self.state.get('udid'), d.get('lastUsedAt', ''), d['udid']), default=None)
        if selected:
            self.reserve(selected['name'], reusable=reusable)
            self.identify(selected['udid'])
        for index, device in enumerate(managed):
            if selected and device['udid'] == selected['udid']:
                continue
            # Recheck state/identity immediately before deletion.
            current = next((d for d in simulator_devices() if d['udid'] == device['udid']), None)
            if current is None:
                continue
            if current['state'] != 'Shutdown' or current['name'] != device['name']:
                raise RuntimeError('Managed simulator changed during cleanup')
            if not self.runner.run(f'simulator-prune-{index}', ['xcrun', 'simctl', 'delete', device['udid']], timeout=60):
                raise RuntimeError('Could not delete unused managed simulator')
        if selected:
            return selected['udid']
        if delete_all:
            self.journal.unlink(missing_ok=True)
            self.state = {}
            return None
        self.reserve('RideIntercom Audio E2E ' + uuid.uuid4().hex[:8], reusable=reusable)
        if not self.runner.run('simulator-create', ['xcrun', 'simctl', 'create', self.state['name'], device_type, runtime], timeout=60):
            raise RuntimeError('Could not create managed simulator')
        device_id = (self.runner.out / 'simulator-create.log').read_text().strip()
        self.identify(device_id)
        return device_id

    def cleanup_host(self, prefix):
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
        return success

    def cleanup(self, prefix):
        success = self.cleanup_host(prefix)
        if not self.state:
            return success
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
