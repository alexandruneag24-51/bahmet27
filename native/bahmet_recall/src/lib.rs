//! # `bahmet_recall` — Memoria
//!
//! Depozitul de vectori și căutarea prin similaritate.
//!
//! ## De ce partea asta e în Rust și vectorizarea nu e
//!
//! Vectorizarea se face o dată per bucată de text, pe GPU, prin Ollama.
//! Căutarea se face la **fiecare întrebare**, peste **tot** corpusul: 100.000
//! de bucăți × 768 de dimensiuni înseamnă 76 de milioane de înmulțiri, de
//! fiecare dată când cineva întreabă ceva.
//!
//! Aceea e munca unde Rust bate BEAM cu două ordine de mărime, și e muncă
//! pură: fără I/O, fără așteptare, doar aritmetică asupra unui bloc contiguu
//! de memorie. Exact ce trebuie să facă Apa.
//!
//! ## Structura: miez pur, coajă subțire
//!
//! Aceeași disciplină ca în `bahmet_vault`. Toată logica trăiește în funcții
//! care întorc `Result<_, RecallError>`, fără nicio urmă de rustler. Atomii
//! Erlang apar exclusiv la frontieră.
//!
//! Lecția a costat un debug întreg data trecută: construirea unui atom cere
//! mașina virtuală pornită, deci orice logică amestecată cu atomi devine
//! imposibil de testat cu `cargo test`. Iar cod netestabil în izolare, în
//! practică, nu e testat deloc.

use rustler::{Atom, NifResult, Resource, ResourceArc};
use std::sync::RwLock;

/// Vectori de peste 4096 de dimensiuni nu vin de la niciun model de embedding
/// cunoscut. Ne cunoaștem marginile *înainte* de a aloca.
const MAX_DIMENSION: usize = 4096;

// ═══════════════════════════════════════════════════════════════════════
//  EROAREA — pură, testabilă
// ═══════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecallError {
    /// Vectorul nu are forma memoriei. Cea mai probabilă cauză: ai schimbat
    /// modelul de embedding fără să reconstruiești memoria.
    DimensionDiscord,
    /// Normă zero sau neterminată. Un vector care nu are direcție nu poate fi
    /// comparat cu nimic.
    NotFinite,
    UnboundedMemory,
    Unknown,
}

mod atoms {
    rustler::atoms! {
        ok,
        dimension_discord,
        not_finite,
        unbounded_memory,
        unknown,
    }
}

impl RecallError {
    fn as_atom(self) -> Atom {
        match self {
            Self::DimensionDiscord => atoms::dimension_discord(),
            Self::NotFinite => atoms::not_finite(),
            Self::UnboundedMemory => atoms::unbounded_memory(),
            Self::Unknown => atoms::unknown(),
        }
    }
}

impl From<RecallError> for rustler::Error {
    fn from(error: RecallError) -> Self {
        rustler::Error::Term(Box::new(error.as_atom()))
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  MEMORIA
// ═══════════════════════════════════════════════════════════════════════

/// Ce s-a adunat.
///
/// Vectorii stau într-un singur `Vec<f32>` contiguu, nu într-un `Vec<Vec<f32>>`.
/// Diferența nu e cosmetică: un bloc continuu înseamnă că procesorul citește
/// secvențial și preîncarcă singur linia următoare. Cu vectori separați, fiecare
/// comparație ar fi un salt în altă zonă de memorie — de câteva ori mai lent,
/// pe exact aceeași aritmetică.
///
/// `RwLock` fiindcă adăugările sunt rare și căutările sunt dese: mulți cititori
/// deodată, un scriitor din când în când. Exact tiparul pentru care există.
pub struct Memory {
    dimension: usize,
    /// Rând-major, `dimension` valori per amintire. **Normalizați la inserare**,
    /// ca să nu recalculăm norma la fiecare căutare.
    vectors: RwLock<Vec<f32>>,
    /// Identitățile, în aceeași ordine. Erlang ține cuvintele; aici stau doar
    /// numerele și legătura dintre ele.
    ids: RwLock<Vec<i64>>,
}

#[rustler::resource_impl]
impl Resource for Memory {}

impl std::fmt::Debug for Memory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Memory")
            .field("dimension", &self.dimension)
            .field("remembered", &self.len())
            .finish()
    }
}

impl Memory {
    fn new(dimension: usize) -> Result<Self, RecallError> {
        if dimension == 0 || dimension > MAX_DIMENSION {
            return Err(RecallError::UnboundedMemory);
        }
        Ok(Self {
            dimension,
            vectors: RwLock::new(Vec::new()),
            ids: RwLock::new(Vec::new()),
        })
    }

    fn len(&self) -> usize {
        match self.ids.read() {
            Ok(guard) => guard.len(),
            Err(poisoned) => poisoned.into_inner().len(),
        }
    }

    /// Adaugă o amintire. Vectorul e normalizat aici, o singură dată.
    ///
    /// Normalizarea la inserare transformă cosinusul într-un simplu produs
    /// scalar la căutare. O împărțire făcută acum economisește o rădăcină
    /// pătrată per amintire, la fiecare întrebare, pentru totdeauna.
    fn remember(&self, id: i64, vector: &[f64]) -> Result<(), RecallError> {
        if vector.len() != self.dimension {
            return Err(RecallError::DimensionDiscord);
        }
        let unit = normalize(vector)?;

        let mut vectors = write(&self.vectors);
        let mut ids = write(&self.ids);
        vectors.extend_from_slice(&unit);
        ids.push(id);
        Ok(())
    }

    /// Uită o amintire. Șterge și vectorul, nu doar identitatea.
    ///
    /// „Uită-mă" trebuie să fie executabil, nu o etichetă. Un vector marcat ca
    /// șters, dar rămas în memorie, e o promisiune pe care sistemul nu o ține.
    fn forget(&self, id: i64) -> usize {
        let mut ids = write(&self.ids);
        let mut vectors = write(&self.vectors);
        let mut removed = 0;
        let mut index = 0;
        while index < ids.len() {
            if ids[index] == id {
                ids.remove(index);
                let start = index * self.dimension;
                vectors.drain(start..start + self.dimension);
                removed += 1;
            } else {
                index += 1;
            }
        }
        removed
    }

    /// Cele mai apropiate `k` amintiri.
    ///
    /// `chunks_exact(self.dimension)` e piesa centrală, ca și în `bahmet_deep`:
    /// îi *demonstrează* compilatorului că fiecare felie e un vector complet.
    /// Nu există niciun index, deci nu există nicio ieșire din memorie posibilă,
    /// nici măcar teoretic. Borrow-checker-ul nu încetinește calculul — e chiar
    /// dovada lui de corectitudine.
    fn recall(&self, query: &[f64], k: usize) -> Result<Vec<(i64, f64)>, RecallError> {
        if query.len() != self.dimension {
            return Err(RecallError::DimensionDiscord);
        }
        let needle = normalize(query)?;

        let vectors = read(&self.vectors);
        let ids = read(&self.ids);

        let mut scored: Vec<(i64, f32)> = vectors
            .chunks_exact(self.dimension)
            .zip(ids.iter())
            .map(|(row, id)| {
                // Ambii vectori sunt unitari, deci produsul scalar ESTE
                // cosinusul unghiului dintre ei. Nicio rădăcină pătrată aici.
                let score: f32 = row.iter().zip(needle.iter()).map(|(a, b)| a * b).sum();
                (*id, score)
            })
            // Un scor neterminat înseamnă o amintire coruptă. O sărim în tăcere
            // în loc să otrăvim clasamentul cu NaN, care compară fals cu tot.
            .filter(|(_, score)| score.is_finite())
            .collect();

        // Sortare completă, apoi trunchiere. Pentru sub un milion de amintiri e
        // sub o milisecundă și e evident corectă. O grămadă mărginită ar fi mai
        // rapidă asimptotic; nu merită complexitatea până nu se dovedește.
        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        scored.truncate(k);

        Ok(scored.into_iter().map(|(id, s)| (id, f64::from(s))).collect())
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  MIEZUL PUR
// ═══════════════════════════════════════════════════════════════════════

/// Aduce vectorul la lungime 1. Refuză ce nu are direcție.
fn normalize(vector: &[f64]) -> Result<Vec<f32>, RecallError> {
    let norm: f64 = vector.iter().map(|v| v * v).sum::<f64>().sqrt();
    if !norm.is_finite() || norm <= 0.0 {
        return Err(RecallError::NotFinite);
    }
    let unit: Vec<f32> = vector.iter().map(|v| (v / norm) as f32).collect();
    if unit.iter().any(|v| !v.is_finite()) {
        return Err(RecallError::NotFinite);
    }
    Ok(unit)
}

/// Introspecția nu are voie să omoare ființa pe care o observă: dacă lacătul a
/// fost otrăvit de o panică anterioară, îl recuperăm în loc să intrăm în panică.
fn read<T>(lock: &RwLock<T>) -> std::sync::RwLockReadGuard<'_, T> {
    match lock.read() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn write<T>(lock: &RwLock<T>) -> std::sync::RwLockWriteGuard<'_, T> {
    match lock.write() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  COAJA — NIF-uri subțiri
// ═══════════════════════════════════════════════════════════════════════

#[rustler::nif]
fn open_memory(dimension: usize) -> NifResult<ResourceArc<Memory>> {
    Ok(ResourceArc::new(Memory::new(dimension)?))
}

#[rustler::nif]
fn remember(memory: ResourceArc<Memory>, id: i64, vector: Vec<f64>) -> NifResult<Atom> {
    memory.remember(id, &vector)?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn forget(memory: ResourceArc<Memory>, id: i64) -> usize {
    memory.forget(id)
}

/// `DirtyCpu`: căutarea peste un corpus mare poate dura zeci de milisecunde.
/// Un NIF care ține un planificator BEAM normal peste ~1 ms înfometează toate
/// celelalte ființe de pe acel fir. Politețea nu e opțională, e arhitectură.
#[rustler::nif(schedule = "DirtyCpu")]
fn recall(memory: ResourceArc<Memory>, query: Vec<f64>, k: usize) -> NifResult<Vec<(i64, f64)>> {
    Ok(memory.recall(&query, k)?)
}

#[derive(rustler::NifMap)]
struct MemoryStatus {
    dimension: usize,
    remembered: usize,
}

#[rustler::nif]
fn status(memory: ResourceArc<Memory>) -> MemoryStatus {
    MemoryStatus {
        dimension: memory.dimension,
        remembered: memory.len(),
    }
}

rustler::init!("bahmet_recall");

// ═══════════════════════════════════════════════════════════════════════
//  PROBE — pe funcțiile reale, fără mașină virtuală
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn memory(dimension: usize) -> Memory {
        Memory::new(dimension).expect("dimensiune valida")
    }

    #[test]
    fn memoria_refuza_forme_imposibile() {
        assert_eq!(Memory::new(0).unwrap_err(), RecallError::UnboundedMemory);
        assert_eq!(
            Memory::new(MAX_DIMENSION + 1).unwrap_err(),
            RecallError::UnboundedMemory
        );
    }

    #[test]
    fn amintirea_de_alta_forma_e_refuzata() {
        let m = memory(4);
        assert_eq!(
            m.remember(1, &[1.0, 0.0, 0.0]).unwrap_err(),
            RecallError::DimensionDiscord
        );
    }

    /// Cel mai probabil mod real de eșec: ai schimbat modelul de embedding și
    /// memoria veche are altă formă. Trebuie să se vadă, nu să dea vecini absurzi.
    #[test]
    fn intrebarea_de_alta_forma_e_refuzata() {
        let m = memory(4);
        m.remember(1, &[1.0, 0.0, 0.0, 0.0]).unwrap();
        assert_eq!(
            m.recall(&[1.0, 0.0], 1).unwrap_err(),
            RecallError::DimensionDiscord
        );
    }

    #[test]
    fn un_vector_fara_directie_e_refuzat() {
        let m = memory(3);
        assert_eq!(
            m.remember(1, &[0.0, 0.0, 0.0]).unwrap_err(),
            RecallError::NotFinite
        );
        assert_eq!(normalize(&[f64::NAN, 1.0, 0.0]), Err(RecallError::NotFinite));
    }

    /// Proba centrală: cel mai apropiat vecin e cel mai apropiat, iar
    /// clasamentul e ordonat descrescător.
    #[test]
    fn cel_mai_apropiat_e_primul() {
        let m = memory(3);
        m.remember(10, &[1.0, 0.0, 0.0]).unwrap();
        m.remember(20, &[0.9, 0.1, 0.0]).unwrap();
        m.remember(30, &[0.0, 0.0, 1.0]).unwrap();

        let found = m.recall(&[1.0, 0.0, 0.0], 3).unwrap();
        assert_eq!(found.len(), 3);
        assert_eq!(found[0].0, 10);
        assert_eq!(found[1].0, 20);
        assert_eq!(found[2].0, 30);
        assert!(found[0].1 > found[1].1 && found[1].1 > found[2].1);
    }

    /// Normalizarea la inserare înseamnă că lungimea nu contează, doar direcția.
    #[test]
    fn marimea_nu_conteaza_doar_directia() {
        let m = memory(3);
        m.remember(1, &[1.0, 0.0, 0.0]).unwrap();
        m.remember(2, &[100.0, 0.0, 0.0]).unwrap();
        let found = m.recall(&[5.0, 0.0, 0.0], 2).unwrap();
        assert!((found[0].1 - 1.0).abs() < 1e-5);
        assert!((found[1].1 - 1.0).abs() < 1e-5);
    }

    #[test]
    fn cere_mai_mult_decat_exista() {
        let m = memory(2);
        m.remember(1, &[1.0, 0.0]).unwrap();
        assert_eq!(m.recall(&[1.0, 0.0], 100).unwrap().len(), 1);
    }

    #[test]
    fn memoria_goala_nu_isi_aminteste_nimic() {
        assert_eq!(memory(4).recall(&[1.0, 0.0, 0.0, 0.0], 5).unwrap(), vec![]);
    }

    /// „Uită-mă" trebuie să șteargă și vectorul, nu doar identitatea. Un vector
    /// marcat ca șters, dar rămas, e o promisiune pe care sistemul nu o ține.
    #[test]
    fn uitarea_sterge_si_numerele() {
        let m = memory(2);
        m.remember(1, &[1.0, 0.0]).unwrap();
        m.remember(2, &[0.0, 1.0]).unwrap();
        assert_eq!(m.forget(1), 1);
        assert_eq!(m.len(), 1);
        assert_eq!(read(&m.vectors).len(), 2);

        let found = m.recall(&[1.0, 0.0], 5).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].0, 2);
    }

    #[test]
    fn uitarea_a_ceva_ce_nu_exista_e_linistita() {
        let m = memory(2);
        m.remember(1, &[1.0, 0.0]).unwrap();
        assert_eq!(m.forget(99), 0);
        assert_eq!(m.len(), 1);
    }

    #[test]
    fn debug_nu_scoate_vectorii() {
        let m = memory(2);
        m.remember(1, &[1.0, 0.0]).unwrap();
        let printed = format!("{:?}", m);
        assert!(printed.contains("remembered"));
        assert!(!printed.contains("1.0"));
    }
}
