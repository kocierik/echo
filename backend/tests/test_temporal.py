"""Tests for temporal filter extraction."""

from datetime import datetime, timezone

from app.services.temporal import extract_date_range

# Fixed "now" for deterministic tests: Wednesday 2026-07-22 10:00 UTC
NOW = datetime(2026, 7, 22, 10, 0, 0, tzinfo=timezone.utc)


class TestExtractDateRange:
    def test_ieri(self):
        result = extract_date_range("cosa mi ha detto Marco ieri?", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-07-21"
        assert result.date_to.date().isoformat() == "2026-07-21"

    def test_yesterday(self):
        result = extract_date_range("what happened yesterday?", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-07-21"

    def test_oggi(self):
        result = extract_date_range("cosa è successo oggi?", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-07-22"
        assert result.date_to.date().isoformat() == "2026-07-22"

    def test_questa_settimana(self):
        result = extract_date_range("riassumi questa settimana", now=NOW)
        assert result is not None
        # Wednesday → Monday of same week
        assert result.date_from.date().isoformat() == "2026-07-20"
        assert result.date_to.date().isoformat() == "2026-07-22"

    def test_settimana_scorsa(self):
        result = extract_date_range("cosa è successo settimana scorsa?", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-07-13"
        assert result.date_to.date().isoformat() == "2026-07-19"

    def test_questo_mese(self):
        result = extract_date_range("riassumi questo mese", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-07-01"
        assert result.date_to.date().isoformat() == "2026-07-22"

    def test_mese_scorso(self):
        result = extract_date_range("cosa è successo mese scorso?", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-06-01"
        assert result.date_to.date().isoformat() == "2026-06-30"

    def test_ultimi_3_giorni(self):
        result = extract_date_range("cosa è successo negli ultimi 3 giorni?", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-07-19"
        assert result.date_to.date().isoformat() == "2026-07-22"

    def test_last_5_days(self):
        result = extract_date_range("what happened in the last 5 days?", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-07-17"

    def test_2_giorni_fa(self):
        result = extract_date_range("cosa mi ha detto 2 giorni fa?", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-07-20"
        assert result.date_to.date().isoformat() == "2026-07-20"

    def test_lunedi_scorso(self):
        # NOW is Wednesday Jul 22, so last Monday = Jul 20
        result = extract_date_range("lunedì scorso ho parlato con Marco", now=NOW)
        assert result is not None
        assert result.date_from.date().isoformat() == "2026-07-20"

    def test_no_temporal_reference(self):
        result = extract_date_range("chi è Marco?", now=NOW)
        assert result is None

    def test_no_temporal_generic_question(self):
        result = extract_date_range("quali task devo ancora fare?", now=NOW)
        assert result is None
