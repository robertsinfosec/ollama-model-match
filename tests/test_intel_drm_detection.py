"""Run: python3 -m unittest discover -s tests -v (requires Python yq and jq)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IntelDrmDetectionTests(unittest.TestCase):
    def test_drm_vendor_identification_in_both_entrypoints(self):
        cases = [('0x10de', 'none'), ('0x1002', 'none'), ('0x8086', 'intel'),
                 ('0xffff', 'none'), (None, 'none')]
        for vendor, expected in cases:
            with self.subTest(vendor=vendor), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                bin_dir = root / 'bin'
                bin_dir.mkdir()
                drm = root / 'sys/class/drm'
                dri = root / 'dev/dri'
                dri.mkdir(parents=True)
                if vendor is not None:
                    device = drm / 'card0/device'
                    device.mkdir(parents=True)
                    (device / 'vendor').write_text(vendor + '\n')
                    (device / 'mem_info_vram_total').write_text(str(6 * 1024**3))
                    (dri / 'renderD128').touch()
                else:
                    drm.mkdir(parents=True)
                for name, script in {
                    'docker': '#!/bin/sh\nexit 1\n',
                    'ollama': '#!/bin/sh\ntest "$1" = ls\n',
                }.items():
                    path = bin_dir / name
                    path.write_text(script)
                    path.chmod(0o755)
                # Keep tests independent of GPU tools installed on the test machine.
                bash_env = root / 'bash-env'
                bash_env.write_text('''command() {
    if [[ "${1:-}" == -v ]]; then
        case "${2:-}" in
            nvidia-smi|amd-smi|rocm-smi|intel_gpu_top) return 1 ;;
        esac
    fi
    builtin command "$@"
}
''')
                env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}',
                           BASH_ENV=str(bash_env))
                for name in ('00-prereqs.sh', '01-assess.sh'):
                    # Run the public scripts against fixture filesystem paths.
                    source = (ROOT / 'src' / name).read_text()
                    source = source.replace('/sys/class/drm', str(drm))
                    source = source.replace('/dev/dri', str(dri))
                    script = root / name
                    script.write_text(source)
                    result = subprocess.run(['bash', str(script)], env=env,
                                            text=True, capture_output=True, timeout=30)
                    self.assertEqual(result.returncode, 0, (name, result.stderr))
                    if name == '00-prereqs.sh':
                        self.assertIn(f'GPU vendor: {expected}', result.stdout)
                    else:
                        parsed = subprocess.run(
                            ['yq', '-r', '.hardware.gpu_vendor', str(root / 'specs.yaml')],
                            env=env, text=True, capture_output=True, check=True)
                        self.assertEqual(parsed.stdout.strip(), expected)


if __name__ == '__main__':
    unittest.main()
