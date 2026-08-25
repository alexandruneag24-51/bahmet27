//! # `bahmet_deep` — Adâncul
//!
//! Jumătatea Rust a lui Bahmet 27: intuiția (rețeaua) și introspecția
//! (siguranța). Codul de aici nu conține niciun bloc `unsafe` scris de noi —
//! singurul `unsafe` din binar provine din macro-urile `rustler`, care sunt
//! auditate o dată, în amonte, în locul nostru.
//!
//! ## Cele trei promisiuni ale acestui modul
//!
//! 1. **Nu doboară mașina virtuală.** Nu există `panic!`, `unwrap`, `expect`
//!    sau indexare pe niciun drum atins de date venite din BEAM. Orice
//!    neconcordanță devine un termen Erlang, nu o prăbușire de proces OS.
//! 2. **Nu fură timpul altora.** Fiecare funcție grea rulează pe un
//!    planificator murdar (`DirtyCpu`). Un NIF care ține un planificator
//!    normal peste ~1 ms înfometează *toate* celelalte ființe de pe acel
//!    fir — asta ar distruge exact răbdarea și echilibrul pe care le
//!    construim în stratul Erlang. Politețea nu e opțională, e arhitectură.
//! 3. **Se cunoaște pe sine înainte să acționeze.** Fiecare calcul își
//!    inspectează propriile mărimi (finitudine, normă, entropie) *înainte*
//!    de a returna. Introspecția precede afirmația.

use rustler::{Atom, Error as NifError, NifResult, Resource, ResourceArc};
use std::sync::RwLock;

mod atoms {
    rustler::atoms! {
        ok,
        // Ofranda nu are forma temeliei. Nu e o eroare de sistem: e o
        // nepotrivire între ce s-a cerut și ce este.
        dimension_discord,
        // S-a cerut o comuniune fără niciun participant.
        empty_offering,
        // Temelia cerută depășește ce poate fi ținut cu onestitate în memorie.
        unbounded_ground,
        // Calculul a ieșit din domeniul numerelor finite. Preferăm să
        // recunoaștem asta decât să returnăm NaN mai departe în sistem.
        not_finite,
    }
}

/// Limita de sus a unei temelii. Un `dimension` de 2048 înseamnă deja
/// ~16 MiB de ponderi. Introspecția începe cu a-ți cunoaște marginile
/// *înainte* de a aloca, nu după ce alocatorul refuză.
const MAX_DIMENSION: usize = 2048;

// ═══════════════════════════════════════════════════════════════════════
//  INTROSPECȚIA
// ═══════════════════════════════════════════════════════════════════════

/// Ce știe temelia despre propria activitate. Nu e telemetrie pentru
/// operator — e conștiința de sine a resursei, citibilă prin `reflect/1`.
#[derive(Debug, Default, Clone, Copy)]
struct Reflection {
    intuitions: u64,
    refusals: u64,
    last_entropy: f32,
}

/// Raportul de introspecție, așa cum ajunge în Erlang.
///
/// `NifMap` îl codifică drept hartă cu chei-atomi: `#{dimension => 256, ...}`.
/// Alegem harta în locul tuplului fiindcă o hartă poate crește în Faza 2
/// fără a rupe nicio potrivire de tipar existentă în Erlang — compatibilitate
/// prin construcție, nu prin disciplină.
#[derive(Debug, rustler::NifMap)]
struct ReflectionReport {
    dimension: usize,
    intuitions: u64,
    refusals: u64,
    last_entropy: f64,
    max_entropy: f64,
    /// `1.0 - entropie/entropie_maximă`. 0.0 = nedumerire totală (uniformă),
    /// 1.0 = certitudine absolută. O ființă onestă își raportează îndoiala.
    coherence: f64,
}

// ═══════════════════════════════════════════════════════════════════════
//  TEMELIA
// ═══════════════════════════════════════════════════════════════════════

/// `Ground` — temelia comună a cercului.
///
/// Trăiește ca *resursă NIF*: BEAM o numără prin referințe și îi cheamă
/// `Drop` abia când ultimul termen Erlang care o ține dispare. Nu există
/// „eliberare manuală" de scris și nici de uitat.
///
/// Ponderile sunt imutabile după naștere. De aceea `ResourceArc<Ground>`
/// poate fi ținut simultan de oricâte ființe fără nicio blocare: partajarea
/// e sigură *pentru că* nimic nu se schimbă. Singurul lucru mutabil —
/// contoarele de introspecție — stă separat, sub `RwLock`, exact ca să nu
/// contamineze calea fierbinte.
#[derive(Debug)]
pub struct Ground {
    dimension: usize,
    /// Matrice `dimension × dimension`, ordonată pe linii.
    weights: Vec<f32>,
    bias: Vec<f32>,
    reflection: RwLock<Reflection>,
}

// Rustler ≥ 0.34. Pentru versiuni mai vechi, se înlocuiește cu o funcție
// `load` care apelează `rustler::resource!(Ground, env)`.
#[rustler::resource_impl]
impl Resource for Ground {}

impl Ground {
    /// Proiecție + neliniaritate, într-o singură trecere.
    ///
    /// `chunks_exact(self.dimension)` este piesa centrală: îi *demonstrează*
    /// compilatorului că fiecare felie e o linie completă de matrice. Nu
    /// există niciun index, deci nu există nicio ieșire din matrice posibilă,
    /// nici măcar teoretic. Borrow-checker-ul nu e o birocrație care încetinește
    /// calculul — aici este chiar dovada de corectitudine a calculului.
    fn project(&self, x: &[f32]) -> Vec<f32> {
        debug_assert_eq!(x.len(), self.dimension);

        self.weights
            .chunks_exact(self.dimension)
            .zip(self.bias.iter())
            .map(|(row, bias)| {
                // `zip` se oprește la cel mai scurt: chiar dacă invariantul
                // de mai sus ar fi încălcat, rezultatul e trunchiat, nu corupt.
                let dot: f32 = row.iter().zip(x.iter()).map(|(w, v)| w * v).sum();
                gelu(dot + bias)
            })
            .collect()
    }

    /// Actualizează conștiința de sine.
    ///
    /// Dacă lacătul a fost otrăvit de o panică anterioară, îl *recuperăm*.
    /// Motivul e filozofic și practic deopotrivă: introspecția nu are voie
    /// să omoare ființa pe care o observă. O statistică pierdută e un preț
    /// mult mai mic decât un proces prăbușit.
    fn note<F: FnOnce(&mut Reflection)>(&self, f: F) {
        match self.reflection.write() {
            Ok(mut guard) => f(&mut guard),
            Err(poisoned) => f(&mut poisoned.into_inner()),
        }
    }

    fn observe(&self) -> Reflection {
        match self.reflection.read() {
            Ok(guard) => *guard,
            Err(poisoned) => *poisoned.into_inner(),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  NIF-URI
// ═══════════════════════════════════════════════════════════════════════

/// Deschide o temelie deterministă.
///
/// Deterministă înseamnă: aceeași sămânță → aceleași ponderi, pe orice
/// mașină. Un sistem care pretinde intuiție trebuie să fie reproductibil,
/// altfel „intuiția" e doar zgomot cu presă bună.
#[rustler::nif]
fn open_ground(dimension: usize, seed: u64) -> NifResult<ResourceArc<Ground>> {
    // Refuzăm *înainte* de a aloca. O temelie imposibilă nu e o excepție
    // de memorie, e o cerere greșită — și îi spunem apelantului pe nume.
    if dimension == 0 || dimension > MAX_DIMENSION {
        return Err(NifError::Term(Box::new(atoms::unbounded_ground())));
    }

    let mut rng = SplitMix64::new(seed);
    // Scalare Xavier: menține varianța activărilor stabilă prin adâncime.
    let scale = (1.0 / dimension as f32).sqrt();

    let weights: Vec<f32> = (0..dimension * dimension)
        .map(|_| rng.next_unit() * scale)
        .collect();

    Ok(ResourceArc::new(Ground {
        dimension,
        weights,
        bias: vec![0.0; dimension],
        reflection: RwLock::new(Reflection::default()),
    }))
}

/// **Intuiția.** Primește o ofrandă, întoarce o distribuție de probabilitate.
///
/// `schedule = "DirtyCpu"`: aici e linia cea mai importantă din tot fișierul.
/// Fără ea, un singur `intuit` pe o temelie de 2048 ar bloca un planificator
/// BEAM zeci de milisecunde, iar toate ființele programate pe acel fir ar
/// aștepta — nu răbdător, ci înfometate. Cu ea, calculul greu se mută pe un
/// fir dedicat și cercul continuă să respire.
///
/// Marginea acceptă `Vec<f64>` fiindcă float-urile Erlang *sunt* f64;
/// convertim la f32 înăuntru. În Faza 2, calea fierbinte va folosi
/// `rustler::Binary` pentru zero copiere.
#[rustler::nif(schedule = "DirtyCpu")]
fn intuit(ground: ResourceArc<Ground>, offering: Vec<f64>) -> NifResult<(Atom, Vec<f64>)> {
    if offering.len() != ground.dimension {
        ground.note(|r| r.refusals += 1);
        // Ridicăm o excepție în loc să întoarcem `{error, _}`: o ofrandă de
        // altă formă este o eroare a *apelantului*, nu o stare de așteptat.
        // Bahmet alege „let it crash": supervizorul are perspectiva mai largă
        // și decide el ce înseamnă asta, nu funcția de aici.
        return Err(NifError::Term(Box::new(atoms::dimension_discord())));
    }

    let x: Vec<f32> = offering.iter().map(|&v| v as f32).collect();
    let projected = ground.project(&x);

    let Some((probabilities, entropy)) = softmax_with_entropy(&projected) else {
        ground.note(|r| r.refusals += 1);
        return Err(NifError::Term(Box::new(atoms::not_finite())));
    };

    ground.note(|r| {
        r.intuitions += 1;
        r.last_entropy = entropy;
    });

    Ok((
        atoms::ok(),
        probabilities.into_iter().map(f64::from).collect(),
    ))
}

/// **Comuniunea.** Topește mai multe înțelegeri într-una singură.
///
/// Media aritmetică, nu maximul și nu prima: nicio ofrandă nu domină, niciuna
/// nu e ignorată. Rezultatul e renormalizat pe simplex, deci rămâne o
/// distribuție validă — întregul păstrează forma părților.
#[rustler::nif(schedule = "DirtyCpu")]
fn commune(offerings: Vec<Vec<f64>>) -> NifResult<(Atom, Vec<f64>)> {
    let Some(first) = offerings.first() else {
        return Err(NifError::Term(Box::new(atoms::empty_offering())));
    };

    let dimension = first.len();
    if dimension == 0 || offerings.iter().any(|o| o.len() != dimension) {
        return Err(NifError::Term(Box::new(atoms::dimension_discord())));
    }

    let count = offerings.len() as f64;
    let mut centroid = vec![0.0_f64; dimension];

    // Împărțim la `count` în interiorul buclei, nu la sfârșit: împiedică
    // acumularea unei sume mari și pierderea de precizie la cozile mici.
    for offering in &offerings {
        for (slot, value) in centroid.iter_mut().zip(offering.iter()) {
            *slot += value / count;
        }
    }

    let total: f64 = centroid.iter().sum();
    if !total.is_finite() || total <= 0.0 {
        return Err(NifError::Term(Box::new(atoms::not_finite())));
    }
    for slot in centroid.iter_mut() {
        *slot /= total;
    }

    Ok((atoms::ok(), centroid))
}

/// **Introspecția.** Ieftină, fără efecte, mereu reușită.
///
/// Nu e marcată `DirtyCpu` tocmai fiindcă e ieftină: a muta pe un
/// planificator murdar un calcul de câteva microsecunde ar costa mai mult
/// decât calculul însuși. A ști ce e greu și ce e ușor face parte din
/// aceeași disciplină.
#[rustler::nif]
fn reflect(ground: ResourceArc<Ground>) -> ReflectionReport {
    let observed = ground.observe();
    let max_entropy = (ground.dimension as f64).ln();

    let coherence = if max_entropy > 0.0 {
        (1.0 - f64::from(observed.last_entropy) / max_entropy).clamp(0.0, 1.0)
    } else {
        0.0
    };

    ReflectionReport {
        dimension: ground.dimension,
        intuitions: observed.intuitions,
        refusals: observed.refusals,
        last_entropy: f64::from(observed.last_entropy),
        max_entropy,
        coherence,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  MATEMATICĂ
// ═══════════════════════════════════════════════════════════════════════

/// Softmax numeric stabil, plus entropia Shannon a rezultatului (în nats).
///
/// Scăderea vârfului înaintea exponențierii nu e o optimizare, e condiția
/// ca funcția să fie definită: fără ea, `exp(89.0)` deja depășește f32.
/// Întoarce `None` în loc să propage NaN — o funcție care nu poate răspunde
/// onest tace, nu inventează.
fn softmax_with_entropy(logits: &[f32]) -> Option<(Vec<f32>, f32)> {
    let peak = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    if !peak.is_finite() {
        return None;
    }

    let exponentiated: Vec<f32> = logits.iter().map(|v| (v - peak).exp()).collect();
    let total: f32 = exponentiated.iter().sum();
    if !total.is_finite() || total <= 0.0 {
        return None;
    }

    let probabilities: Vec<f32> = exponentiated.iter().map(|e| e / total).collect();

    // `filter` elimină zerourile: `0 * ln(0)` este NaN în virgulă mobilă,
    // deși limita matematică e 0. Grija pentru cazul degenerat, nu ignorarea lui.
    let entropy = -probabilities
        .iter()
        .filter(|p| **p > 0.0)
        .map(|p| p * p.ln())
        .sum::<f32>();

    Some((probabilities, entropy))
}

/// GELU, aproximarea tanh.
fn gelu(x: f32) -> f32 {
    const SQRT_2_OVER_PI: f32 = 0.797_884_56;
    const COEFF: f32 = 0.044_715;
    0.5 * x * (1.0 + (SQRT_2_OVER_PI * (x + COEFF * x * x * x)).tanh())
}

/// SplitMix64 — generator determinist, fără dependențe externe.
///
/// Toate operațiile sunt `wrapping_*`: în Rust, depășirea la întregi este
/// panică în build-ul de debug. Un NIF care intră în panică într-un build de
/// debug e o bombă cu ceas. Declarăm explicit că depășirea e *intenția*.
struct SplitMix64(u64);

impl SplitMix64 {
    fn new(seed: u64) -> Self {
        Self(seed ^ 0x2727_2727_2727_2727)
    }

    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform în (-1.0, 1.0), folosind cei 24 de biți semnificativi ai f32.
    fn next_unit(&mut self) -> f32 {
        const SPAN: f32 = (1_u32 << 24) as f32;
        let bits = (self.next_u64() >> 40) as f32;
        (bits / SPAN) * 2.0 - 1.0
    }
}

// Pentru Erlang pur, numele modulului este simplu. (Într-un proiect Elixir
// ar fi `"Elixir.Bahmet.Deep"`.) Rustler ≥ 0.34 descoperă singur funcțiile
// marcate cu `#[rustler::nif]`.
rustler::init!("bahmet_deep");

// ═══════════════════════════════════════════════════════════════════════
//  PROBE
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn ground(dim: usize) -> Ground {
        let mut rng = SplitMix64::new(27);
        let scale = (1.0 / dim as f32).sqrt();
        Ground {
            dimension: dim,
            weights: (0..dim * dim).map(|_| rng.next_unit() * scale).collect(),
            bias: vec![0.0; dim],
            reflection: RwLock::new(Reflection::default()),
        }
    }

    #[test]
    fn softmax_este_o_distributie() {
        let (p, _) = softmax_with_entropy(&[1.0, 2.0, 3.0]).expect("finit");
        assert!((p.iter().sum::<f32>() - 1.0).abs() < 1e-5);
        assert!(p.iter().all(|v| *v >= 0.0));
    }

    #[test]
    fn softmax_supravietuieste_valorilor_extreme() {
        // Fără scăderea vârfului, aici ar rezulta inf/inf = NaN.
        let (p, _) = softmax_with_entropy(&[1000.0, 999.0, 998.0]).expect("finit");
        assert!(p.iter().all(|v| v.is_finite()));
    }

    #[test]
    fn softmax_tace_in_loc_sa_minta() {
        assert!(softmax_with_entropy(&[f32::NAN, 1.0]).is_none());
        assert!(softmax_with_entropy(&[f32::INFINITY]).is_none());
    }

    #[test]
    fn entropia_e_maxima_cand_totul_e_egal() {
        let (_, h) = softmax_with_entropy(&[0.0; 8]).expect("finit");
        assert!((h - 8.0_f32.ln()).abs() < 1e-4);
    }

    #[test]
    fn proiectia_pastreaza_dimensiunea() {
        let g = ground(16);
        assert_eq!(g.project(&[0.5; 16]).len(), 16);
    }

    #[test]
    fn temelia_e_determinista() {
        assert_eq!(ground(8).weights, ground(8).weights);
    }
}
