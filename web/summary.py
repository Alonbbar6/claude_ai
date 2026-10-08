"""Close-day summary: Claude phrases it, ordinary code computes it.

`write_summary(facts)` sends the computed facts to Claude and returns prose.
A grounding check rejects any output that mentions a number not present in
the facts; in that case (or with no API access) a fixed template is used, so
the demo never depends on the model.
"""

from __future__ import annotations

import json
import os
import re

MODEL = "claude-opus-5-5"

SYSTEM = """You write the end-of-day summary for a small restaurant's inventory dashboard.
You receive computed facts as JSON. Rules:
- Use only the facts given. Do not calculate, estimate, or invent any number.
- Every quantity, count or price you mention must appear verbatim in the facts.
- Stock figures are recipe-based estimates, not physical counts; call them "estimated".
- The restaurant and all channel integrations are simulated demo data; do not claim real integrations.
- Output exactly these four markdown headings, each with 1-3 short sentences or bullets, no preamble:
### Sales
### Inventory
### Alerts and actions
### Tomorrow
Write plainly for a restaurant owner."""

_NUM = re.compile(r"\d[\d,]*(?:\.\d+)?")


def _numbers(text: str) -> set[str]:
    return {t.replace(",", "").rstrip(".") for t in _NUM.findall(text)}


def allowed_numbers(facts: dict) -> set[str]:
    """Every number that appears in the facts, in the forms the model may write it."""
    out: set[str] = set()
    for n in _numbers(json.dumps(facts)):
        out.add(n)
        try:
            v = float(n)
        except ValueError:
            continue
        out |= {f"{v:.0f}", f"{v:.1f}", f"{v:.2f}", f"{v:g}"}
        if v.is_integer():
            out.add(str(int(v)))
    return out


def grounding_check(summary: str, facts: dict) -> list[str]:
    """Numbers in the summary that are not in the facts (empty = grounded)."""
    allowed = allowed_numbers(facts)
    return sorted(n for n in _numbers(summary) if n and n not in allowed)


def fallback_summary(f: dict) -> str:
    s, inv = f["sales"], f["inventory"]
    chans = ", ".join(f"{k} {v['orders']}" for k, v in s["by_channel"].items()) or "no channel activity"
    top = ", ".join(f"{d['dish']} ×{d['quantity']}" for d in s["top_dishes"]) or "none"
    low = "; ".join(f"{l['ingredient']} {l['status']} at an estimated {l['estimated_on_hand']} {l['unit']} "
                    f"(alert level {l['threshold']})" for l in inv["low_or_out_now"]) or "no ingredients at or below their alert level"
    alerts = ", ".join(f"{a['ingredient']} ({a['kind']}, {a['at']})" for a in f["alerts_raised"]) or "none"
    specials = "; ".join(f"{sp['dish']} at ${sp['special_price']} to use {sp['ingredient']} "
                         f"({sp['days_of_cover']} days of cover)" for sp in f["overstock_specials"]) or "none"
    adjustments = "; ".join(f"{c['ingredient']} {c['adjustment']:+} {c['unit']}" for c in inv["count_adjustments"]) or "none"
    tomorrow = []
    if inv["low_or_out_now"]:
        tomorrow.append("restock the low ingredients or keep the affected dishes paused")
    if f["overstock_specials"]:
        tomorrow.append("run the suggested special")
    tomorrow.append("confirm a physical count before trusting the estimates")
    return (f"### Sales\n{s['orders']} orders, ${s['revenue']} revenue ({chans}). Top dishes: {top}.\n\n"
            f"### Inventory\nEstimated stock: {low}. Count adjustments today: {adjustments}.\n\n"
            f"### Alerts and actions\nAlerts raised today: {alerts}. Overstock special: {specials}.\n\n"
            f"### Tomorrow\n{'; '.join(tomorrow).capitalize()}.")


def write_summary(facts: dict) -> dict:
    result = {"source": "fallback", "model": None, "grounded": True, "ungrounded_numbers": [], "reason": None}
    if os.environ.get("BARMADE_SUMMARY_AI", "on").lower() in ("off", "0", "false"):
        result["reason"] = "AI summary disabled (BARMADE_SUMMARY_AI=off)"
        result["text"] = fallback_summary(facts)
        return result
    try:
        import anthropic
        client = anthropic.Anthropic(timeout=60.0, max_retries=1)
        response = client.beta.messages.create(
            model=MODEL, max_tokens=1500,
            betas=["server-side-fallback-2026-07-01"], fallbacks="default",
            system=SYSTEM,
            messages=[{"role": "user", "content": "Facts for today:\n" + json.dumps(facts, indent=1)}],
        )
        if response.stop_reason == "refusal":
            raise RuntimeError("model declined the request")
        text = "".join(b.text for b in response.content if b.type == "text").strip()
        bad = grounding_check(text, facts)
        if bad:
            result.update(reason=f"AI text mentioned numbers not in the facts: {bad}", ungrounded_numbers=bad, grounded=False)
            result["text"] = fallback_summary(facts)
            return result
        result.update(source="claude", model=response.model, text=text)
        return result
    except Exception as e:  # no key, network down, SDK missing: the demo must still close the day
        result["reason"] = f"{type(e).__name__}: {str(e)[:160]}"
        result["text"] = fallback_summary(facts)
        return result
