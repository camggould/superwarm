# How Superwarm estimates emissions

Superwarm turns the token counts your coding agents already log into energy
and carbon estimates. Nobody outside the model providers can measure inference
energy directly, so every figure is an **estimate with a range**. This
document explains each step, every coefficient, and where it comes from. The
code lives in [`engine/src/emissions.rs`](../engine/src/emissions.rs) and the
sources in [`engine/src/citations.rs`](../engine/src/citations.rs). The macOS app
and the `superwarm` CLI run the same engine.

## 1. Reading usage

| Tool | Logs | What's counted |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | The `usage` block of each API response. One response is logged once per content block, so lines are merged by message id + request id. |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl[.zst]` | The growth in the running `total_token_usage` between `token_count` events. A resumed session starts from `last_token_usage`, so inherited history isn't counted twice. Records are keyed by rollout file, because forked and subagent rollouts can reuse their parent's session id. |

Tokens are split into four kinds because they cost very different amounts of compute:

- **Output**: generated one at a time. Each is a full forward pass (decode).
- **Uncached input**: processed in parallel in one prefill pass.
- **Cache write**: input processed and stored in the prompt cache.
- **Cache read**: input whose attention keys and values are already cached.

Logs are found in the same places on macOS and Linux. Nothing is uploaded. The
only network request is the macOS app's update check against GitHub.

## 2. Energy per token

```
output-equivalents = output
                   + input       × r_in
                   + cache write × r_in × r_write
                   + cache read  × r_in × r_read

IT energy (Wh)     = output-equivalents / 1000 × E_base × m_tier × f^years
facility energy    = IT energy × PUE
CO₂e (g)           = facility energy (kWh) × grid intensity (g/kWh)
```

| Symbol | Central | 90% range | Meaning |
|---|---|---|---|
| `E_base` | 0.9 Wh | 0.32–2.5 | Per 1,000 output tokens, large frontier model, mid-2024 generation, incl. host and idle capacity |
| `m_tier` | 1 / 0.45 / 0.12 | ×÷1.8 / ×÷2.2 | Large / medium / small model |
| `r_in` | 0.2 | 0.1–0.4 | Uncached input token vs output token |
| `r_read` | 0.1 | 0.04–0.25 | Cache read vs uncached input token |
| `r_write` | 1.0 | 0.77–1.3 | Cache write vs uncached input token |
| `f` | 0.6 / year | 0.38–0.96 | Energy-per-token change per year of model generation |
| PUE | 1.15 | (setting) | Facility energy ÷ IT energy |
| Grid | 373 g/kWh | (setting) | US average, location-based |

### Baseline: `E_base` = 0.9 Wh per 1,000 output tokens

Two independent estimates for GPT-4o-class models in 2024–25:

- **Epoch AI (2025)**: ~0.3 Wh for a typical ~500-token GPT-4o reply on H100s
  (≈ 0.6 Wh / 1k tokens). It assumes 1,500 W per GPU including server
  overhead at 70% utilisation, and Epoch calls it an upper-leaning estimate.
- **Jegham et al. (2025), "How Hungry is AI?"**: ~0.42 Wh for a short GPT-4o
  query including data-centre overhead (≈ 1.25 Wh / 1k output tokens before PUE).

The central value sits between them. Google's own measurements show why idle
capacity and host power must be included: its accelerator-only accounting gives
0.10 Wh per median Gemini prompt, against 0.24 Wh comprehensive
([Google, 2025](https://arxiv.org/abs/2508.15734)). The ×÷2.8 spread covers
both studies with room to spare.

### Model size: `m_tier`

Vendors don't publish parameter counts, so models are bucketed by product line
(Opus / flagship = large, Sonnet = medium, Haiku / mini / nano / flash = small).
The multipliers follow API pricing as a proxy for serving compute, the same
argument Epoch uses for GPT-4o-mini. Medium models cost ~0.4–0.6× and small
ones ~0.1–0.2× per output token. Measured open-model energy per token
([ML.ENERGY](https://arxiv.org/abs/2505.06371)) scales the same way with
active parameters. Unknown models are treated as medium, with a wider range.

### Input and caching: `r_in`, `r_read`, `r_write`

Prefill processes the whole prompt in parallel at high utilisation, so an
input token costs a fraction of a decoded token. 0.2 matches both the physics
(compute-bound prefill vs memory-bound decode) and vendors' 1:4–1:8
input:output price ratios. A cache read skips most of the prefill compute, and
vendors price it at ~10% of input. Agentic coding re-reads billions of cached
tokens, so this weighting dominates totals and is called out in the range.

### The efficiency trend: `f` = 0.6 per year

Energy per token is falling fast:

- **Hardware**: measured B200 energy per token is ~1.7× better than H100.
  H200 uses 0.61–0.84× of H100's energy per token on matched models
  ([Chung et al., 2026](https://arxiv.org/abs/2601.22076)).
- **Software and serving**: lower-precision inference (FP8/FP4), speculative
  decoding, mixture-of-experts and better batching.
- **Measured fleet-wide**: Google reports a **33×** drop in energy per median
  Gemini prompt in the 12 months to May 2025.

Superwarm assumes 0.6× per year (1.67× better), well below Google's figure and
close to hardware-only gains. Each model's generation is its release month
from a built-in catalogue. Unknown models fall back to when they first appear
in your logs, a late bound when your history is short; correct it in
`models.json` (Settings → Models). Extrapolation is clamped at ±4 years, and
the range widens by ×÷1.6 per year extrapolated.

### Uncertainty

Each coefficient's spread is treated as a log-normal 90% interval. Spreads
combine in quadrature in log space, with input-side ratios weighted by their
share of the energy. Every record shares the same coefficients, so errors are
fully correlated: totals sum their bounds rather than shrinking them.

## 3. Counterfactuals

- **vs 2024 models**: the same tokens with each model's generation set to the
  reference (mid-2024), keeping its size tier.
- **How bad it could have been** (Year in Carbon): the 2024 counterfactual,
  then additionally every cache read and write processed as uncached input.
- **Smaller models** (tip): large-tier work re-costed at the medium tier. This
  assumes the smaller model could do the same work in the same tokens, which
  holds for routine work but not always for hard problems.
- **Previous period**: the same stretch of the earlier period, up to the same
  point, and only if your logs cover it.

## 4. Everyday comparisons

| Comparison | Per unit | Source |
|---|---|---|
| Mile driven | 400 g | [EPA](https://www.epa.gov/greenvehicles/greenhouse-gas-emissions-typical-passenger-vehicle) |
| Round-trip commute | 2 × your miles × 400 g (default 11.7 mi each way) | [FHWA NHTS 2017](https://nhts.ornl.gov/assets/2017_nhts_summary_travel_trends.pdf) |
| Gallon of gasoline | 8,887 g | [EPA](https://www.epa.gov/greenvehicles/greenhouse-gas-emissions-typical-passenger-vehicle) |
| Quarter-pound beef burger | 113 g × 99.5 kg CO₂e/kg | [Our World in Data / Poore & Nemecek](https://ourworldindata.org/environmental-impacts-of-food) |
| Short-haul flight km | 151 g | [Our World in Data](https://ourworldindata.org/travel-carbon-footprint) |
| Flight New York → LA | 3,980 km × 151 g | [Our World in Data](https://ourworldindata.org/travel-carbon-footprint) |
| Train km | 35 g (UK national rail) | [Our World in Data](https://ourworldindata.org/travel-carbon-footprint) |
| Hour of video streaming | 36 g | [IEA](https://www.iea.org/commentaries/the-carbon-footprint-of-streaming-video-fact-checking-the-headlines) |
| Day / hour of home electricity | 29.6 kWh / day × grid | [EIA](https://www.eia.gov/tools/faqs/faq.php?id=97&t=3) |
| Kettle boil | 0.1 kWh × grid (1 L, +80 °C) | physics |
| iPhone charge | 20 Wh × grid | ~15 Wh battery at ~75% charger efficiency |
| MacBook charge | 60 Wh × grid | [Apple](https://www.apple.com/macbook-air/specs/), 52.6 Wh battery |
| Hot shower | 2.3 kWh × grid (10 min, 2.0 gpm, +25 °C) | [EPA WaterSense](https://www.epa.gov/watersense/showerheads) + physics |
| Year of an LED bulb | 10 W × 8,766 h × grid | [DOE](https://www.energy.gov/energysaver/led-lighting) |
| Day of an average American | 14.3 t / 365.25 | [Our World in Data](https://ourworldindata.org/co2-emissions) |
| Tree-decade of absorption | 60 kg | [EPA](https://www.epa.gov/energy/greenhouse-gas-equivalencies-calculator-calculations-and-references) |

## 5. What's not included

- **Training**, amortised over a model's lifetime. Mistral's life-cycle analysis
  attributes most of its footprint to training and inference combined
  ([Mistral, 2025](https://mistral.ai/news/our-contribution-to-a-global-environmental-standard-for-ai)).
- **Embodied emissions** of GPUs, servers and buildings.
- **Water use.**
- **Your own laptop and network.**
- **Market-based accounting**: renewable purchases by providers aren't credited.
  If you know which region serves you, pick a lower grid preset.

Found a better source, or think a coefficient is off? Please
[open an issue](https://github.com/camggould/superwarm/issues) with a link. The
model is meant to improve as providers publish more.
