import os
import sys

# Make scripts/ importable without packaging the repo
sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
)
