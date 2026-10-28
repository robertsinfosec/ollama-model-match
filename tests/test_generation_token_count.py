"""Run: python3 -m unittest discover -s tests -v (no Ollama server required)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GenerationTokenCountTests(unittest.TestCase):
    def test_generated_count_is_distinct_from_prompt_count(self):
        for generated in (200, 0):
            with self.subTest(generated=generated), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                bin_dir = root / 'bin'
                bin_dir.mkdir()
                (root / 'results').mkdir()
                (root / 'specs.yaml').write_text('{}\n')
                (root / 'results/qualifying.txt').write_text(
                    'fixture:3b|high|ollama|2.41|2.0\n')
                shutil.copy(ROOT / 'src/05-benchmark.sh', root / '05-benchmark.sh')
                for name, script in {
                    'docker': '#!/bin/sh\nexit 1\n',
                    'ollama': '''#!/bin/sh
case "$1" in
  ls) exit 0 ;;
  run)
    cat >/dev/null
    printf 'prompt eval rate: 1000.00 tokens/s\n'
    printf 'prompt eval count: 100 token(s)\n'
    printf 'eval rate: 10.00 tokens/s\n'
    printf 'eval count: %s token(s)\n' "$GENERATED_COUNT"
    ;;
  *) exit 1 ;;
esac
''',
                }.items():
                    path = bin_dir / name
                    path.write_text(script)
                    path.chmod(0o755)
                env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}',
                           GENERATED_COUNT=str(generated))
                result = subprocess.run(['bash', str(root / '05-benchmark.sh')],
                                        env=env, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'tokens: {generated} |', result.stdout)
                self.assertNotIn('tokens: 100 |', result.stdout)


if __name__ == '__main__':
    unittest.main()
