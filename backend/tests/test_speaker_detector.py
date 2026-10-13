"""Unit tests for speaker detection logic."""

from app.services.speaker_detector import classify_energy, compute_threshold


class TestComputeThreshold:
    def test_empty_list(self):
        assert compute_threshold([]) is None

    def test_single_value(self):
        assert compute_threshold([100]) == 100

    def test_percentile_70(self):
        # 10 values: threshold should be around the 70th percentile
        values = list(range(100, 200, 10))  # [100,110,120,...,190]
        threshold = compute_threshold(values)
        assert 150 <= threshold <= 180

    def test_typical_distribution(self):
        # Simulate: user speaks loudly (high energy), others are quieter
        energies = [3000, 3200, 2800, 3100, 2900,  # self (loud)
                    800, 900, 750, 850, 700]         # other (quiet)
        threshold = compute_threshold(energies)
        # Should be high enough to separate the two clusters
        assert threshold > 1500


class TestClassifyEnergy:
    def test_above_threshold_is_self(self):
        assert classify_energy(3000, 2000) == "self"

    def test_below_threshold_is_other(self):
        assert classify_energy(800, 2000) == "other"

    def test_equal_to_threshold_is_self(self):
        assert classify_energy(2000, 2000) == "self"

    def test_no_threshold_is_unknown(self):
        assert classify_energy(3000, None) == "unknown"

    def test_no_energy_is_unknown(self):
        assert classify_energy(None, 2000) == "unknown"


class TestConfigurablePercentile:
    VALUES = list(range(100, 200, 10))  # [100, 110, ..., 190]

    def test_default_percentile_is_seventy(self):
        from app.core.config import settings

        assert settings.speaker_threshold_percentile == 0.7
        assert compute_threshold(self.VALUES) == 170

    def test_explicit_percentile(self):
        assert compute_threshold(self.VALUES, percentile=0.3) == 130

    def test_configured_percentile_is_used(self, monkeypatch):
        from app.core.config import settings

        monkeypatch.setattr(settings, "speaker_threshold_percentile", 0.3)

        assert compute_threshold(self.VALUES) == 130

    def test_percentile_is_clamped_to_the_data(self):
        assert compute_threshold(self.VALUES, percentile=1.0) == 190
        assert compute_threshold(self.VALUES, percentile=0.0) == 100
