"""Load the comparison CLI without installing the source tree as a package."""

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
module_spec = importlib.util.spec_from_file_location("comparison_cli", ROOT / "src/12-compare.py")
compare = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(compare)
