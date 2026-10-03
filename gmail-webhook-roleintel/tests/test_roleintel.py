import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import roleintel as r  # noqa: E402

STYLE = {"TITLE": "TITLE", "H1": "HEADING_1", "H2": "HEADING_2"}


def fake_doc(blocks):
    content = []
    for kind, text in blocks:
        for line in text.split("\n"):
            content.append({"paragraph": {
                "paragraphStyle": {"namedStyleType": STYLE.get(kind, "NORMAL_TEXT")},
                "elements": [{"textRun": {"content": line + "\n",
                                          "textStyle": {"italic": True} if kind == "META" else {}}}]}})
    return {"body": {"content": content}}


def sections():
    return [
        r.Section(key="a", title="Company Brief",
                  versions=[r.Version(model="claude", at="2026-10-03T10:00:00Z", text="Line one\n\nLine three 🚀"),
                            r.Version(model="gpt", at="2026-10-01", text="older"),
                            r.Version(model="grok", at="2026-09-30", text="oldest")],
                  counsel=[r.Counsel(model="gemini", at="2026-10-03", target="original", text="counsel A"),
                           r.Counsel(model="grok", at="2026-10-02", target="", text="counsel B")]),
        r.Section(key="b", title="Questions", versions=[r.Version(model="claude", at="2026-10-03", text="Q1")]),
    ]


def test_roundtrip():
    blocks = [("BRAND", "launch."), ("TITLE", "Doc"), ("LABEL", "Contents"), ("TOC", "Company Brief"), ("TOC", "Questions")]
    for s in sections():
        blocks += r.render_section(s)
    parsed = r.parse_document(fake_doc(blocks))
    assert [p["title"] for p in parsed] == ["Company Brief", "Questions"]
    first = parsed[0]
    assert first["versions"] == [
        {"model": "claude", "at": "2026-10-03", "text": "Line one\n\nLine three 🚀"},
        {"model": "gpt", "at": "2026-10-01", "text": "older"},
        {"model": "grok", "at": "2026-09-30", "text": "oldest"},
    ]
    assert first["counsel"] == [
        {"model": "gemini", "at": "2026-10-03", "target": "original", "text": "counsel A"},
        {"model": "grok", "at": "2026-10-02", "target": "", "text": "counsel B"},
    ]
    assert parsed[1]["counsel"] == []


def test_layout_uses_utf16_indices():
    text, spans = r.layout([("BODY", "a🚀"), ("H1", "x")], start=1)
    assert text == "a🚀\nx\n"
    assert spans == [("BODY", 1, 5), ("H1", 5, 7)]  # 🚀 is two UTF-16 units


def test_layout_tail_and_lead():
    text, spans = r.layout([("H1", "x")], start=10, lead="\n", tail=False)
    assert text == "\nx"
    assert spans == [("H1", 11, 13)]


def test_previous_versions_capped():
    s = r.Section(title="T", versions=[r.Version(model=str(i), at="2026-01-01") for i in range(5)])
    prev = [t for k, t in r.render_section(s) if t.startswith("Previous version")]
    assert len(prev) == r.MAX_PREVIOUS_VERSIONS


def test_headings_not_given_explicit_text_style():
    _, spans = r.layout([("H1", "x"), ("BODY", "y")], start=1)
    reqs = r.style_requests(spans)
    assert sum("updateTextStyle" in q for q in reqs) == 1
