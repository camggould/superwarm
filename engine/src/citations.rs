//! Published sources behind every number in the model. Generated from the
//! original Swift list; keep docs/METHODOLOGY.md in sync when editing.

use serde::Serialize;

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Citation {
    pub id: &'static str,
    pub title: &'static str,
    pub publisher: &'static str,
    pub year: u16,
    pub url: &'static str,
    /// What we take from the source, in one sentence.
    pub used_for: &'static str,
}

pub const ALL: &[Citation] = &[
    Citation {
        id: "epoch-2025",
        title: "How much energy does ChatGPT use?",
        publisher: "Epoch AI",
        year: 2025,
        url: "https://epoch.ai/gradient-updates/how-much-energy-does-chatgpt-use",
        used_for: "~0.3 Wh for a typical GPT-4o reply (~500 output tokens) on H100s, an upper-leaning estimate. One anchor for the 2024 baseline.",
    },
    Citation {
        id: "jegham-2025",
        title: "How Hungry is AI? Benchmarking Energy, Water, and Carbon Footprint of LLM Inference",
        publisher: "Jegham et al., arXiv:2505.09598",
        year: 2025,
        url: "https://arxiv.org/abs/2505.09598",
        used_for: "~0.42 Wh for a short GPT-4o query (incl. data-centre overhead), and a 65x+ spread between the most and least efficient models. Second anchor for the baseline and the tier spread.",
    },
    Citation {
        id: "google-2025",
        title: "Measuring the environmental impact of delivering AI at Google scale",
        publisher: "Google, arXiv:2508.15734",
        year: 2025,
        url: "https://arxiv.org/abs/2508.15734",
        used_for: "Median Gemini text prompt = 0.24 Wh / 0.03 gCO2e. Energy per prompt fell 33x in 12 months. Accelerator-only accounting gives 0.10 Wh, so idle capacity and host overhead must be counted.",
    },
    Citation {
        id: "chung-2026",
        title: "Where Do the Joules Go? Diagnosing Inference Energy Consumption",
        publisher: "Chung et al. (ML.ENERGY), arXiv:2601.22076",
        year: 2026,
        url: "https://arxiv.org/abs/2601.22076",
        used_for: "Measured H100 and B200 energy per token across 46 models. Reasoning workloads cost ~2.1x more per token, because long sequences limit batch size.",
    },
    Citation {
        id: "mlenergy-2025",
        title: "The ML.ENERGY Benchmark: Toward Automated Inference Energy Measurement and Optimization",
        publisher: "Chung et al., arXiv:2505.06371",
        year: 2025,
        url: "https://arxiv.org/abs/2505.06371",
        used_for: "Open, measured per-token inference energy for open-weight models. Basis for the prefill-versus-decode and size scaling.",
    },
    Citation {
        id: "mistral-2025",
        title: "Our contribution to a global environmental standard for AI",
        publisher: "Mistral AI",
        year: 2025,
        url: "https://mistral.ai/news/our-contribution-to-a-global-environmental-standard-for-ai",
        used_for: "Full life-cycle figure of 1.14 gCO2e per 400-token Le Chat reply (incl. hardware manufacturing). A cross-check that our per-reply grams are in the right range.",
    },
    Citation {
        id: "egrid-2022",
        title: "eGRID2022 Summary Data (US total output emission rate)",
        publisher: "US EPA",
        year: 2024,
        url: "https://www.epa.gov/egrid/summary-data",
        used_for: "US average grid intensity of ~823 lb CO2/MWh (~373 g/kWh). Default location-based grid factor.",
    },
    Citation {
        id: "ember-2025",
        title: "Global Electricity Review 2025",
        publisher: "Ember",
        year: 2025,
        url: "https://ember-energy.org/latest-insights/global-electricity-review-2025/",
        used_for: "World average grid intensity of ~473 gCO2/kWh in 2024.",
    },
    Citation {
        id: "google-pue",
        title: "Power usage effectiveness",
        publisher: "Google Data Centers",
        year: 2024,
        url: "https://datacenters.google/efficiency/",
        used_for: "Hyperscale fleet PUE of ~1.09–1.10. Industry surveys report ~1.5 for typical facilities. Default PUE 1.15 sits between them, leaning hyperscale.",
    },
    Citation {
        id: "epa-vehicle",
        title: "Greenhouse Gas Emissions from a Typical Passenger Vehicle",
        publisher: "US EPA",
        year: 2023,
        url: "https://www.epa.gov/greenvehicles/greenhouse-gas-emissions-typical-passenger-vehicle",
        used_for: "~400 g CO2 per mile for an average passenger car, and 8,887 g CO2 per gallon of gasoline.",
    },
    Citation {
        id: "epa-equivalencies",
        title: "Greenhouse Gas Equivalencies Calculator: Calculations and References",
        publisher: "US EPA",
        year: 2024,
        url: "https://www.epa.gov/energy/greenhouse-gas-equivalencies-calculator-calculations-and-references",
        used_for: "~60 kg CO2 taken up by one urban tree seedling grown for 10 years.",
    },
    Citation {
        id: "iea-streaming",
        title: "The carbon footprint of streaming video: fact-checking the headlines",
        publisher: "IEA (G. Kamiya)",
        year: 2020,
        url: "https://www.iea.org/commentaries/the-carbon-footprint-of-streaming-video-fact-checking-the-headlines",
        used_for: "~36 g CO2 per hour of streamed video (2019 global average).",
    },
    Citation {
        id: "owid-transport",
        title: "Which form of transport has the smallest carbon footprint?",
        publisher: "Our World in Data (from UK BEIS factors)",
        year: 2023,
        url: "https://ourworldindata.org/travel-carbon-footprint",
        used_for: "~151 g CO2e per passenger-km for a short-haul flight, including non-CO2 warming.",
    },
    Citation {
        id: "owid-food",
        title: "Environmental Impacts of Food Production (Poore & Nemecek 2018 data)",
        publisher: "Our World in Data",
        year: 2021,
        url: "https://ourworldindata.org/environmental-impacts-of-food",
        used_for: "~99.5 kg CO2e per kg of beef from beef herds (global mean incl. supply-chain losses).",
    },
    Citation {
        id: "owid-co2",
        title: "CO2 emissions per capita",
        publisher: "Our World in Data / Global Carbon Project",
        year: 2024,
        url: "https://ourworldindata.org/co2-emissions",
        used_for: "US fossil CO2 of ~14.3 t per person per year.",
    },
    Citation {
        id: "nhts-2017",
        title: "Summary of Travel Trends: 2017 National Household Travel Survey",
        publisher: "US FHWA",
        year: 2018,
        url: "https://nhts.ornl.gov/assets/2017_nhts_summary_travel_trends.pdf",
        used_for: "Average US commute trip of ~11.7 miles one way. Default commute length.",
    },
    Citation {
        id: "eia-home",
        title: "How much electricity does an American home use?",
        publisher: "US EIA",
        year: 2023,
        url: "https://www.eia.gov/tools/faqs/faq.php?id=97&t=3",
        used_for: "Average US home uses ~10,791 kWh of electricity per year (2022), about 29.6 kWh a day.",
    },
    Citation {
        id: "epa-watersense",
        title: "WaterSense Labeled Showerheads",
        publisher: "US EPA",
        year: 2024,
        url: "https://www.epa.gov/watersense/showerheads",
        used_for: "Standard showerhead flow of 2.5 gpm (WaterSense: ≤2.0). A 10-minute shower at 2.0 gpm heated by 25 °C needs ~2.2 kWh of heat, ~2.3 kWh from an electric heater.",
    },
    Citation {
        id: "apple-mba",
        title: "MacBook Air 13-inch Technical Specifications",
        publisher: "Apple",
        year: 2024,
        url: "https://www.apple.com/macbook-air/specs/",
        used_for: "52.6 Wh battery. At ~85% charger efficiency a full charge draws ~60 Wh from the wall.",
    },
    Citation {
        id: "doe-led",
        title: "LED Lighting",
        publisher: "US Department of Energy",
        year: 2024,
        url: "https://www.energy.gov/energysaver/led-lighting",
        used_for: "A ~10 W LED replaces a 60 W incandescent bulb. Left on all year it uses ~88 kWh.",
    },
];

pub fn by_id(id: &str) -> Option<&'static Citation> {
    ALL.iter().find(|c| c.id == id)
}
