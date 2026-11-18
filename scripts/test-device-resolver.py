#!/usr/bin/env python3
"""Tests the device resolver in run-on-device.sh without building or installing anything.

The fixture preserves the captured Xcode 27 structure with identifiers scrubbed.
"""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).with_name('run-on-device.sh')
SOURCE = SCRIPT.read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
FIXTURE = json.loads(Path(__file__).with_name('fixtures').joinpath('devicectl-xcode27.json').read_text())
PHONE = next(d for d in FIXTURE['result']['devices'] if d.get('deviceProperties', {}).get('developerModeStatus') == 'enabled')
UDID = PHONE['hardwareProperties']['udid']

class ResolverTests(unittest.TestCase):
    def resolve(self, data, selector):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'devices.json'
            path.write_text(json.dumps(data))
            return subprocess.run([sys.executable, '-c', SOURCE, str(path), selector], capture_output=True, text=True)

    def success(self, data=FIXTURE, selector=UDID):
        result = self.resolve(data, selector)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), UDID)
        return result

    def phoneOnly(self):
        return {'result': {'devices': [copy.deepcopy(PHONE)]}}

    def testCapturedShapeByUDIDExactNameAndCoreDeviceIdentifier(self):
        for selector in (UDID, PHONE['deviceProperties']['name'], PHONE['identifier']):
            with self.subTest(selector=selector): self.success(selector=selector)

    def testEnabledDictionaryAndStringAndExplicitStringPreference(self):
        for mode in ('dict', 'string', 'preferred'):
            data = self.phoneOnly(); d = data['result']['devices'][0]
            d['deviceProperties']['ddiServicesAvailable'] = True
            if mode == 'dict': del d['deviceProperties']['developerModeStatus']
            if mode == 'string': d['properties']['state']['developerModeStatus'] = 'enabled'
            if mode == 'preferred': d['properties']['state']['developerModeStatus'] = {'disabled': {}}
            with self.subTest(mode=mode): self.success(data)

    def testLegacyShape(self):
        data = self.phoneOnly(); del data['result']['devices'][0]['properties']
        self.success(data)

    def testDDIUnavailableOnlyWarns(self):
        result = self.success()
        self.assertIn('Warning:', result.stderr)
        self.assertIn('Developer Disk Image', result.stderr)

    def testDisabledInBothShapes(self):
        for mode in ('string', 'dict'):
            data = self.phoneOnly(); d = data['result']['devices'][0]
            d['deviceProperties'].pop('developerModeStatus')
            d['properties']['state']['developerModeStatus'] = 'disabled' if mode == 'string' else {'disabled': {}}
            result = self.resolve(data, UDID)
            self.assertNotEqual(result.returncode, 0); self.assertIn('Developer Mode is disabled', result.stderr)

    def testLockedUntrustedAndUnpairedDiagnostics(self):
        for field, value, diagnostic in [('lockState', {'locked': {}}, 'locked'), ('trustState', 'untrusted', 'untrusted'), ('pairingState', 'unpaired', 'unpaired')]:
            data = self.phoneOnly(); d = data['result']['devices'][0]
            d['properties']['state'][field] = value
            result = self.resolve(data, UDID)
            self.assertNotEqual(result.returncode, 0); self.assertIn(diagnostic, result.stderr)

    def testSimulatorAndWatchRejected(self):
        for d in FIXTURE['result']['devices']:
            h = d.get('hardwareProperties', {})
            if h.get('reality') != 'physical' or h.get('deviceType') != 'iPhone':
                result = self.resolve(FIXTURE, h['udid'])
                self.assertNotEqual(result.returncode, 0); self.assertEqual(result.stdout, '')

    def testNotFoundAndAmbiguousDiagnostics(self):
        result = self.resolve(FIXTURE, 'absent')
        self.assertNotEqual(result.returncode, 0); self.assertIn('No physical iPhone', result.stderr)
        data = self.phoneOnly(); data['result']['devices'].append(copy.deepcopy(PHONE))
        result = self.resolve(data, UDID)
        self.assertNotEqual(result.returncode, 0); self.assertIn('Multiple physical iPhones', result.stderr)

if __name__ == '__main__': unittest.main()
