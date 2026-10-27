#!/usr/bin/env python3
"""Run the complete backend's loopback-only archive/download fixtures."""
from pathlib import Path
import runpy

if __name__ == "__main__":
    runpy.run_path(str(Path(__file__).with_name("install-pipe-check.py")))["main"]("download")
