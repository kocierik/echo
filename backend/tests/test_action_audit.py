from app.actions.audit import summarize_arguments


def test_argument_summary_hides_bodies():
    s = summarize_arguments({"to": "ada@x.it", "body": "x" * 500})
    assert "ada@x.it" in s
    assert "(500 chars)" in s
    assert "x" * 50 not in s


def test_summary_truncates_values_and_total():
    s = summarize_arguments({"a": "y" * 200})
    assert len(s) < 100
    big = {f"k{i}": "v" * 80 for i in range(20)}
    assert len(summarize_arguments(big)) <= 300
