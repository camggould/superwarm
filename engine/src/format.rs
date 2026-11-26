//! Human-readable quantities: three significant figures, trailing zeros dropped.

/// "0.42 g", "12.3 g", "1.2 kg", "267 kg", "3.1 t".
pub fn grams(g: f64) -> String {
    let a = g.abs();
    if a >= 1_000_000.0 {
        format!("{} t", significant(g / 1_000_000.0))
    } else if a >= 1_000.0 {
        format!("{} kg", significant(g / 1_000.0))
    } else if a >= 0.01 || a == 0.0 {
        format!("{} g", significant(g))
    } else {
        format!("{g:.1e} g")
    }
}

/// "0.42 Wh", "12.3 Wh", "1.24 kWh", "3.1 MWh".
pub fn energy(wh: f64) -> String {
    let a = wh.abs();
    if a >= 1_000_000.0 {
        format!("{} MWh", significant(wh / 1_000_000.0))
    } else if a >= 1_000.0 {
        format!("{} kWh", significant(wh / 1_000.0))
    } else {
        format!("{} Wh", significant(wh))
    }
}

/// Up to three significant figures (two decimals at most), trailing zeros removed.
pub fn significant(v: f64) -> String {
    let a = v.abs();
    let decimals = if a >= 100.0 { 0 } else if a >= 10.0 { 1 } else { 2 };
    let mut text = format!("{v:.decimals$}");
    if text.contains('.') {
        while text.ends_with('0') {
            text.pop();
        }
        if text.ends_with('.') {
            text.pop();
        }
    }
    text
}

/// Short count: "0.3", "4.2", "37", "1.2k", "3.4M".
pub fn count(n: f64) -> String {
    let a = n.abs();
    if a >= 1_000_000_000.0 {
        format!("{:.1}B", n / 1_000_000_000.0)
    } else if a >= 1_000_000.0 {
        format!("{:.1}M", n / 1_000_000.0)
    } else if a >= 10_000.0 {
        format!("{:.1}k", n / 1_000.0)
    } else if a >= 10.0 {
        format!("{n:.0}")
    } else if a >= 0.1 {
        format!("{n:.1}")
    } else if a == 0.0 {
        "0".to_string()
    } else {
        format!("{n:.2}")
    }
}

pub fn tokens(n: u64) -> String {
    count(n as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_quantities() {
        assert_eq!(grams(0.5), "0.5 g");
        assert_eq!(grams(0.0), "0 g");
        assert_eq!(grams(1_234.0), "1.23 kg");
        assert_eq!(grams(45_590.0), "45.6 kg");
        assert_eq!(grams(266_800.0), "267 kg");
        assert_eq!(grams(10_000.0), "10 kg");
        assert_eq!(energy(2_500.0), "2.5 kWh");
        assert_eq!(count(12_345.0), "12.3k");
        assert_eq!(count(4.0), "4.0");
    }
}
