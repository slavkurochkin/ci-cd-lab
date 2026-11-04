"""Tests of the digest arithmetic and text. Offline, no AWS SDK. Project 18."""

from datetime import UTC, date, datetime, timedelta

from cost_report import alert_text, delta, digest, ranked, runner_section, split_weeks, week_bounds

TODAY = date(2026, 11, 9)
NOW = datetime(2026, 11, 9, 8, 0, tzinfo=UTC)


def day(d: date, groups: dict[str, float]) -> dict:
    return {
        "TimePeriod": {"Start": d.isoformat(), "End": (d + timedelta(days=1)).isoformat()},
        "Groups": [{"Keys": [k], "Metrics": {"UnblendedCost": {"Amount": str(v)}}} for k, v in groups.items()],
    }


def fortnight(before: dict[str, float], after: dict[str, float]) -> list[dict]:
    """14 daily rows: `before` spread over the first 7 days, `after` over the last 7."""
    start = TODAY - timedelta(days=14)
    return [day(start + timedelta(days=i), {k: v / 7 for k, v in (before if i < 7 else after).items()})
            for i in range(14)]


def test_week_bounds() -> None:
    assert week_bounds(TODAY) == (date(2026, 10, 26), date(2026, 11, 2), TODAY)


def test_split_weeks_maps_empty_tag_to_untagged() -> None:
    rows = fortnight({"Lab$13": 7.0, "Lab$": 1.4}, {"Lab$13": 3.5, "Lab$18": 0.7})
    before, after = split_weeks(rows, date(2026, 11, 2))
    assert round(before["13"], 2) == 7.0 and round(before["untagged"], 2) == 1.4
    assert round(after["13"], 2) == 3.5 and round(after["18"], 2) == 0.7
    assert "untagged" not in after


def test_ranked_orders_by_this_week_and_drops_dust() -> None:
    rows = ranked({"a": 1.0, "b": 0.001}, {"a": 0.5, "c": 2.0, "b": 0.002})
    assert [r[0] for r in rows] == ["c", "a"]
    assert rows[1] == ("a", 0.5, -0.5)


def test_delta_signs() -> None:
    assert delta(1.234) == "+$1.23"
    assert delta(-0.5) == "−$0.50"
    assert delta(0.001) == "±$0.00"


def test_digest_text() -> None:
    by_tag = fortnight({"Lab$13": 7.0}, {"Lab$13": 3.5, "Lab$": 0.5})
    by_service = fortnight({"Amazon EKS": 7.0}, {"Amazon EKS": 4.0})
    runner = {"generated_at": "2026-11-09T06:30:00+00:00", "workflows": {"Lab 03 CI": 80.4, "Terraform": 50.0},
              "total_minutes": 130.4, "runs": 120}
    text = digest(by_tag, by_service, runner, TODAY, NOW)
    assert text.startswith("*AWS spend Nov 02 – Nov 08*: $4.00 (−$3.00 on the week before), before credits")
    assert "untagged: $0.50 (12%)" in text
    assert "1. Lab 13: $3.50 (−$3.50)" in text
    assert "2. *untagged*: $0.50 (+$0.50)" in text
    assert "1. Amazon EKS: $4.00 (−$3.00)" in text
    assert "1. Lab 03 CI: 80 min" in text
    assert "total 130 min over 120 runs" in text


def test_runner_section_missing_and_stale() -> None:
    assert "no data" in runner_section(None, NOW)[1]
    old = {"generated_at": "2026-10-20T06:30:00+00:00", "workflows": {}, "total_minutes": 0, "runs": 0}
    assert runner_section(old, NOW)[1].startswith("stale: last written 2026-10-20")


def test_quiet_week() -> None:
    text = digest(fortnight({}, {}), fortnight({}, {}), None, TODAY, NOW)
    assert "$0.00" in text and "untagged: $0.00 (0%)" in text
    assert "nothing over half a cent" in text


def test_alert_text_is_bounded() -> None:
    text = alert_text("x" * 5000, "Budget ci-cd-lab-monthly")
    assert text.startswith(":rotating_light: *Budget ci-cd-lab-monthly*")
    assert len(text) < 2600
