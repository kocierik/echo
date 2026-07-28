"""Quick runner for speaker_detector unit checks without pytest/conftest."""

import sys
from pathlib import Path

# Ensure backend/app is importable as top-level `app`
repo_root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repo_root / "app"))
sys.path.insert(0, str(repo_root))

from app.services.speaker_detector import compute_threshold, classify_energy


def run():
    # Test compute_threshold
    assert compute_threshold([]) is None
    assert compute_threshold([100]) == 100
    values = list(range(100, 200, 10))
    threshold = compute_threshold(values)
    assert 150 <= threshold <= 180
    energies = [3000, 3200, 2800, 3100, 2900, 800, 900, 750, 850, 700]
    threshold = compute_threshold(energies)
    assert threshold > 1500

    # Test classify_energy
    assert classify_energy(3000, 2000) == "self"
    assert classify_energy(800, 2000) == "other"
    assert classify_energy(2000, 2000) == "self"
    assert classify_energy(3000, None) == "unknown"
    assert classify_energy(None, 2000) == "unknown"


if __name__ == "__main__":
    run()
    print("All quick speaker_detector checks passed")
