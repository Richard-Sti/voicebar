"""Check that deletions press Backspace once per user-perceived character.

Run: uv run python test_grapheme_count.py
"""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("voicebar", Path(__file__).parent / "voicebar.py")
lv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lv)

assert lv.grapheme_count("hello world") == 11
assert lv.grapheme_count("café") == 4          # e + combining acute
assert lv.grapheme_count("❤️ ok") == 4      # heart + variation selector
assert lv.grapheme_count("\U0001F469‍\U0001F4BB") == 1  # woman technologist (ZWJ)
assert lv.grapheme_count("") == 0
print("grapheme_count ok")
