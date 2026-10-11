//! # Cifrele cisterciene — chipul codurilor
//!
//! Un cod de memorie are patru părți. Fiecare parte e un număr între 0 și
//! 9.999 (sau 0 și 255, pentru tabelele mici), iar o cifră cisterciană scrie
//! exact un astfel de număr într-un singur semn: o tijă verticală și câte o
//! trăsătură în fiecare cadran.
//!
//! ```text
//!    zeci │ unități
//!   ──────┼──────
//!   mii   │ sute
//! ```
//!
//! Patru semne lipite într-un pătrat 2×2 dau chipul unui cod întreg. Chipul
//! e doar o reprezentare: căutarea lucrează pe numere, nu pe desene.
//!
//! Nu există încă un caracter Unicode pentru aceste cifre, deci le desenăm ca
//! SVG.

/// Cea mai mare valoare pe care o poate scrie un singur semn.
pub const MAX_VALUE: u16 = 9999;

/// O linie, în unități de tijă: x la dreapta tijei e pozitiv, y crește în jos,
/// tija merge de la y = 0 la y = 3.
pub type Stroke = ((f32, f32), (f32, f32));

/// Trăsăturile cifrei `d` în cadranul unităților (sus-dreapta), cu x ∈ [0,1]
/// și y ∈ [0,1].
fn unit_strokes(d: u16) -> Vec<Stroke> {
    let top = ((0.0, 0.0), (1.0, 0.0));
    let mid = ((0.0, 1.0), (1.0, 1.0));
    let down = ((0.0, 0.0), (1.0, 1.0));
    let up = ((0.0, 1.0), (1.0, 0.0));
    let side = ((1.0, 0.0), (1.0, 1.0));
    match d {
        1 => vec![top],
        2 => vec![mid],
        3 => vec![down],
        4 => vec![up],
        5 => vec![top, up],
        6 => vec![side],
        7 => vec![top, side],
        8 => vec![mid, side],
        9 => vec![top, mid, side],
        _ => vec![],
    }
}

/// Toate trăsăturile unui număr, inclusiv tija. `None` peste 9.999.
pub fn strokes(value: u16) -> Option<Vec<Stroke>> {
    if value > MAX_VALUE {
        return None;
    }
    let digits = [value % 10, value / 10 % 10, value / 100 % 10, value / 1000];
    // (oglindire orizontală, oglindire verticală) pentru unități, zeci, sute, mii.
    let mirrors = [(1.0, false), (-1.0, false), (1.0, true), (-1.0, true)];

    let mut out = vec![((0.0, 0.0), (0.0, 3.0))];
    for (digit, (sx, flip)) in digits.iter().zip(mirrors) {
        for ((x1, y1), (x2, y2)) in unit_strokes(*digit) {
            let place = |x: f32, y: f32| (x * sx, if flip { 3.0 - y } else { y });
            out.push((place(x1, y1), place(x2, y2)));
        }
    }
    Some(out)
}

/// Un semn ca fragment SVG, cu tija la `(cx, top)` și unitatea `scale` pixeli.
fn glyph_paths(value: u16, cx: f32, top: f32, scale: f32) -> Option<String> {
    let lines = strokes(value)?;
    let mut d = String::new();
    for ((x1, y1), (x2, y2)) in lines {
        d.push_str(&format!(
            "M{:.1} {:.1}L{:.1} {:.1}",
            cx + x1 * scale,
            top + y1 * scale,
            cx + x2 * scale,
            top + y2 * scale
        ));
    }
    Some(format!("<path d=\"{d}\"/>"))
}

/// Un singur număr, ca SVG de sine stătător.
pub fn glyph_svg(value: u16) -> Option<String> {
    let s = 20.0;
    let body = glyph_paths(value, 1.5 * s, 0.5 * s, s)?;
    Some(wrap(3.0 * s, 4.0 * s, &body))
}

/// Un cod întreg: semnele așezate câte două pe rând, în pătrat pentru patru
/// părți. `None` dacă vreo parte depășește 9.999.
pub fn code_svg(code: &[u16]) -> Option<String> {
    let s = 20.0;
    let (cell_w, cell_h) = (3.0 * s, 4.0 * s);
    let columns = code.len().clamp(1, 2);
    let rows = (code.len() + columns - 1) / columns;
    let mut body = String::new();
    for (i, &value) in code.iter().enumerate() {
        let (col, row) = ((i % columns) as f32, (i / columns) as f32);
        body.push_str(&glyph_paths(
            value,
            col * cell_w + 1.5 * s,
            row * cell_h + 0.5 * s,
            s,
        )?);
    }
    Some(wrap(columns as f32 * cell_w, rows.max(1) as f32 * cell_h, &body))
}

fn wrap(w: f32, h: f32, body: &str) -> String {
    format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w:.0}\" height=\"{h:.0}\" \
         viewBox=\"0 0 {w:.0} {h:.0}\" fill=\"none\" stroke=\"currentColor\" \
         stroke-width=\"2\" stroke-linecap=\"round\">{body}</svg>"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_e_doar_tija() {
        assert_eq!(strokes(0).unwrap(), vec![((0.0, 0.0), (0.0, 3.0))]);
    }

    #[test]
    fn peste_9999_nu_exista_semn() {
        assert!(strokes(10_000).is_none());
        assert!(code_svg(&[1, 2, 10_000, 4]).is_none());
    }

    /// 1 e o linie orizontală sus-dreapta; 1000 e aceeași linie oglindită
    /// jos-stânga.
    #[test]
    fn cadranele_sunt_oglindite_corect() {
        assert_eq!(strokes(1).unwrap()[1], ((0.0, 0.0), (1.0, 0.0)));
        assert_eq!(strokes(10).unwrap()[1], ((-0.0, 0.0), (-1.0, 0.0)));
        assert_eq!(strokes(100).unwrap()[1], ((0.0, 3.0), (1.0, 3.0)));
        assert_eq!(strokes(1000).unwrap()[1], ((-0.0, 3.0), (-1.0, 3.0)));
    }

    /// 9 are trei trăsături în fiecare cadran, plus tija.
    #[test]
    fn noua_mii_noua_sute_are_toate_trasaturile() {
        assert_eq!(strokes(9999).unwrap().len(), 1 + 4 * 3);
    }

    #[test]
    fn fiecare_cifra_e_diferita() {
        let all: Vec<_> = (0..=9).map(unit_strokes).collect();
        for i in 0..all.len() {
            for j in i + 1..all.len() {
                assert_ne!(all[i], all[j], "{i} si {j} arata la fel");
            }
        }
    }

    #[test]
    fn codul_de_patru_parti_e_un_patrat() {
        let svg = code_svg(&[17, 203, 5, 88]).unwrap();
        assert!(svg.starts_with("<svg"));
        assert!(svg.contains("width=\"120\" height=\"160\""));
        assert_eq!(svg.matches("<path").count(), 4);
        assert!(glyph_svg(9999).unwrap().contains("<path"));
    }
}
