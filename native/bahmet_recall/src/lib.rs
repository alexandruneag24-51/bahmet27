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

use rustler::{Atom, Binary, Env, NifResult, OwnedBinary, Resource, ResourceArc};
use std::sync::RwLock;

/// Vectori de peste 4096 de dimensiuni nu vin de la niciun model de embedding
/// cunoscut. Ne cunoaștem marginile *înainte* de a aloca.
const MAX_DIMENSION: usize = 4096;

/// Antetul unui instantaneu. Patru octeți care spun „asta e o memorie Bahmet,
/// versiunea 1" — ca un fișier străin cu extensia potrivită să fie refuzat
/// imediat, nu interpretat ca vectori.
const MAGIC: [u8; 4] = *b"BHM1";
const HEADER: usize = 4 + 4 + 8; // magic + dimensiune + număr

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
    /// Instantaneul nu are forma asteptata. Fisier trunchiat, alta versiune,
    /// sau octeti straini care s-au nimerit sa aiba extensia potrivita.
    Corrupt,
    AllocationFailed,
    Unknown,
}

mod atoms {
    rustler::atoms! {
        ok,
        dimension_discord,
        not_finite,
        unbounded_memory,
        corrupt,
        allocation_failed,
        unknown,
    }
}

impl RecallError {
    fn as_atom(self) -> Atom {
        match self {
            Self::DimensionDiscord => atoms::dimension_discord(),
            Self::NotFinite => atoms::not_finite(),
            Self::UnboundedMemory => atoms::unbounded_memory(),
            Self::Corrupt => atoms::corrupt(),
            Self::AllocationFailed => atoms::allocation_failed(),
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
//  INSTANTANEUL
// ═══════════════════════════════════════════════════════════════════════
//
// Vectorii NU sunt secrete -- sunt numere derivate din text pe care oricum îl
// ai. De aceea `snapshot' există, spre deosebire de `export_key' din seif:
// asimetria de acolo protejează chei, iar aici nu e nimic de protejat.
//
// Formatul e explicit și verificabil, nu `bincode' sau altă serializare care
// se schimbă tăcut între versiuni. Un fișier scris azi trebuie citit peste un
// an, de un binar recompilat, fără surprize.
//
//   "BHM1" · dimensiune u32 BE · număr u64 BE
//   apoi, de `număr' ori: id i64 BE · `dimensiune' × f32 BE

fn snapshot_bytes(memory: &Memory) -> Vec<u8> {
    let vectors = read(&memory.vectors);
    let ids = read(&memory.ids);

    let stride = 8 + memory.dimension * 4;
    let mut out = Vec::with_capacity(HEADER + ids.len() * stride);
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&(memory.dimension as u32).to_be_bytes());
    out.extend_from_slice(&(ids.len() as u64).to_be_bytes());

    // `chunks_exact` din nou: nicio indexare, deci nicio ieșire posibilă.
    for (row, id) in vectors.chunks_exact(memory.dimension).zip(ids.iter()) {
        out.extend_from_slice(&id.to_be_bytes());
        for value in row {
            out.extend_from_slice(&value.to_be_bytes());
        }
    }
    out
}

/// Reconstruiește memoria dintr-un instantaneu.
///
/// Vectorii au fost normalizați la inserare și rămân normalizați aici: un
/// instantaneu păstrează invariantul, nu doar datele. De aceea nu renormalizăm
/// — ar fi muncă în plus pentru același rezultat.
///
/// Tot ce citim din fișier trece prin `get()`, care întoarce `Option`. Niciun
/// index, deci niciun panic posibil pe un fișier trunchiat sau ostil.
fn restore_bytes(blob: &[u8]) -> Result<Memory, RecallError> {
    let magic = blob.get(0..4).ok_or(RecallError::Corrupt)?;
    if magic != MAGIC {
        return Err(RecallError::Corrupt);
    }

    let dimension = read_u32(blob, 4)? as usize;
    let count = read_u64(blob, 8)? as usize;

    if dimension == 0 || dimension > MAX_DIMENSION {
        return Err(RecallError::UnboundedMemory);
    }

    let stride = 8 + dimension * 4;
    let body = blob.get(HEADER..).ok_or(RecallError::Corrupt)?;
    if body.len() != count.saturating_mul(stride) {
        return Err(RecallError::Corrupt);
    }

    let mut vectors = Vec::with_capacity(count * dimension);
    let mut ids = Vec::with_capacity(count);

    for entry in body.chunks_exact(stride) {
        let (id_bytes, vector_bytes) = entry.split_at(8);
        ids.push(i64::from_be_bytes(
            id_bytes.try_into().map_err(|_| RecallError::Corrupt)?,
        ));
        for value in vector_bytes.chunks_exact(4) {
            let quad: [u8; 4] = value.try_into().map_err(|_| RecallError::Corrupt)?;
            let float = f32::from_be_bytes(quad);
            if !float.is_finite() {
                return Err(RecallError::Corrupt);
            }
            vectors.push(float);
        }
    }

    Ok(Memory {
        dimension,
        vectors: RwLock::new(vectors),
        ids: RwLock::new(ids),
    })
}

fn read_u32(blob: &[u8], at: usize) -> Result<u32, RecallError> {
    let slice = blob.get(at..at + 4).ok_or(RecallError::Corrupt)?;
    let quad: [u8; 4] = slice.try_into().map_err(|_| RecallError::Corrupt)?;
    Ok(u32::from_be_bytes(quad))
}

fn read_u64(blob: &[u8], at: usize) -> Result<u64, RecallError> {
    let slice = blob.get(at..at + 8).ok_or(RecallError::Corrupt)?;
    let eight: [u8; 8] = slice.try_into().map_err(|_| RecallError::Corrupt)?;
    Ok(u64::from_be_bytes(eight))
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

/// `DirtyCpu`: un instantaneu de 300 MB nu are ce căuta pe un planificator
/// normal, oricât de simplă e copierea.
#[rustler::nif(schedule = "DirtyCpu")]
fn snapshot<'a>(env: Env<'a>, memory: ResourceArc<Memory>) -> NifResult<Binary<'a>> {
    let bytes = snapshot_bytes(&memory);
    let mut owned = OwnedBinary::new(bytes.len()).ok_or(RecallError::AllocationFailed)?;
    owned.as_mut_slice().copy_from_slice(&bytes);
    Ok(owned.release(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn restore(blob: Binary) -> NifResult<ResourceArc<Memory>> {
    Ok(ResourceArc::new(restore_bytes(blob.as_slice())?))
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

    /// Bucla completă: ce a fost ținut minte se regăsește identic, cu aceleași
    /// identități, aceeași ordine și aceleași scoruri.
    #[test]
    fn instantaneul_se_inchide() {
        let m = memory(3);
        m.remember(10, &[1.0, 0.0, 0.0]).unwrap();
        m.remember(20, &[0.0, 1.0, 0.0]).unwrap();
        m.remember(30, &[0.5, 0.5, 0.0]).unwrap();

        let before = m.recall(&[1.0, 0.0, 0.0], 3).unwrap();
        let restored = restore_bytes(&snapshot_bytes(&m)).unwrap();

        assert_eq!(restored.dimension, 3);
        assert_eq!(restored.len(), 3);
        assert_eq!(restored.recall(&[1.0, 0.0, 0.0], 3).unwrap(), before);
    }

    #[test]
    fn instantaneul_unei_memorii_goale_e_valid() {
        let restored = restore_bytes(&snapshot_bytes(&memory(768))).unwrap();
        assert_eq!(restored.dimension, 768);
        assert_eq!(restored.len(), 0);
    }

    /// Un fișier străin cu extensia potrivită trebuie refuzat imediat, nu
    /// interpretat ca vectori. De aceea există antetul.
    ///
    /// NOTĂ: comparăm EROAREA, nu `Result`-ul. `assert_eq!` pe
    /// `Result<Memory, _>` ar cere `PartialEq` pentru `Memory` — iar sugestia
    /// compilatorului de a-l deriva ar genera o comparație a tuturor
    /// vectorilor, adică muncă masivă pentru un test care vrea doar să știe
    /// că a eșuat. Aceeași capcană ca la `KeyHandle` din seif.
    #[test]
    fn octetii_straini_sunt_refuzati() {
        assert_eq!(restore_bytes(b"nu sunt o memorie").unwrap_err(), RecallError::Corrupt);
        assert_eq!(restore_bytes(&[]).unwrap_err(), RecallError::Corrupt);
        assert_eq!(restore_bytes(&MAGIC).unwrap_err(), RecallError::Corrupt);
    }

    /// Un fișier trunchiat -- disc plin, copiere întreruptă -- nu are voie să
    /// producă o memorie pe jumătate, care ar răspunde plauzibil și incomplet.
    #[test]
    fn instantaneul_trunchiat_e_refuzat() {
        let m = memory(4);
        m.remember(1, &[1.0, 0.0, 0.0, 0.0]).unwrap();
        let full = snapshot_bytes(&m);
        for cut in [1, HEADER, HEADER + 4, full.len() - 1] {
            assert_eq!(restore_bytes(&full[..cut]).unwrap_err(), RecallError::Corrupt);
        }
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
