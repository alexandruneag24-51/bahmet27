//! # Codurile — cuantizare pe produs (product quantization)
//!
//! Un vector de 768 de numere ocupă 3.072 de octeți. Aici îl înlocuim cu un
//! cod scurt: tăiem vectorul în `parts` felii egale și, pentru fiecare felie,
//! păstrăm doar *numărul de ordine* al celei mai apropiate forme dintr-un
//! tabel învățat. Patru felii × un octet = patru octeți în loc de 3.072.
//!
//! Seamănă cu o cifră cisterciană — patru cadrane, fiecare cu valoarea lui —
//! dar fiecare „cadran" aici nu ține o cifră, ci o **adresă** într-un tabel.
//! Tabelele sunt stocate o singură dată și împărțite de toate amintirile;
//! de acolo vine economia.
//!
//! ## Căutarea fără decompresie
//!
//! Vectorii sunt unitari, deci cosinusul e produs scalar, iar produsul scalar
//! se descompune pe felii: `q·x = Σ q_s·x_s`. La fiecare întrebare calculăm o
//! dată tabelul `q_s · c` pentru fiecare formă `c` din fiecare tabel, apoi
//! scorul unei amintiri e suma a `parts` valori citite din tabel. Fără
//! înmulțiri per amintire — doar adunări.
//!
//! ## Ce se pierde
//!
//! Precizia. Codul e o aproximare; vecinii găsiți nu sunt mereu exact cei
//! adevărați. Cât se pierde se măsoară cu `examples/pq_bench.rs`, nu se
//! presupune.

use crate::RecallError;

/// Peste 65.536 de forme pe felie, codul nu mai încape într-un `u16`.
pub const MAX_CENTROIDS: usize = 1 << 16;

/// Tabelele învățate: `parts` tabele, fiecare cu `centroids` forme de lungime
/// `dimension / parts`.
#[derive(Debug, Clone)]
pub struct Codebook {
    pub dimension: usize,
    pub parts: usize,
    pub centroids: usize,
    /// Rând-major: tabelul `s`, forma `c` începe la `(s * centroids + c) * sub`.
    table: Vec<f32>,
}

impl Codebook {
    pub fn sub(&self) -> usize {
        self.dimension / self.parts
    }

    /// Octeți per parte de cod: unul până la 256 de forme, doi peste.
    pub fn bytes_per_part(&self) -> usize {
        if self.centroids <= 256 {
            1
        } else {
            2
        }
    }

    pub fn code_bytes(&self) -> usize {
        self.parts * self.bytes_per_part()
    }

    pub fn table_bytes(&self) -> usize {
        self.table.len() * 4
    }

    fn centroid(&self, part: usize, index: usize) -> &[f32] {
        let sub = self.sub();
        let start = (part * self.centroids + index) * sub;
        &self.table[start..start + sub]
    }

    /// Codul unui vector: pentru fiecare felie, forma cea mai apropiată.
    pub fn encode(&self, vector: &[f32]) -> Vec<u16> {
        let sub = self.sub();
        vector
            .chunks_exact(sub)
            .enumerate()
            .map(|(part, slice)| nearest(self, part, slice) as u16)
            .collect()
    }

    /// Vectorul reconstruit dintr-un cod (aproximativ).
    pub fn decode(&self, code: &[u16]) -> Vec<f32> {
        code.iter()
            .enumerate()
            .flat_map(|(part, &c)| self.centroid(part, c as usize).iter().copied())
            .collect()
    }

    /// Tabelul de scoruri pentru o întrebare: `parts × centroids` produse
    /// scalare. Se calculează o dată per întrebare.
    pub fn score_table(&self, query: &[f32]) -> Vec<f32> {
        let sub = self.sub();
        let mut out = Vec::with_capacity(self.parts * self.centroids);
        for (part, q) in query.chunks_exact(sub).enumerate() {
            for c in 0..self.centroids {
                out.push(dot(q, self.centroid(part, c)));
            }
        }
        out
    }
}

/// Amintirile comprimate: tabelele plus câte un cod per amintire.
#[derive(Debug, Clone)]
pub struct CodedMemory {
    pub book: Codebook,
    /// `parts` valori per amintire, în ordinea din `ids`.
    codes: Vec<u16>,
    pub ids: Vec<i64>,
}

impl CodedMemory {
    /// Comprimă vectori unitari, rând-major. Învață tabelele pe aceiași vectori.
    pub fn build(
        vectors: &[f32],
        ids: &[i64],
        dimension: usize,
        parts: usize,
        centroids: usize,
        iterations: usize,
        seed: u64,
    ) -> Result<Self, RecallError> {
        let book = train(vectors, dimension, parts, centroids, iterations, seed)?;
        let codes = encode_all(&book, vectors);
        Ok(Self { book, codes, ids: ids.to_vec() })
    }

    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    pub fn code(&self, index: usize) -> Option<&[u16]> {
        let p = self.book.parts;
        self.codes.get(index * p..index * p + p)
    }

    pub fn code_of(&self, id: i64) -> Option<&[u16]> {
        let index = self.ids.iter().position(|&x| x == id)?;
        self.code(index)
    }

    /// Octeții ocupați de coduri + tabele (fără identități, ca la comparația
    /// cu vectorii întregi).
    pub fn bytes(&self) -> usize {
        self.len() * self.book.code_bytes() + self.book.table_bytes()
    }

    /// Cele mai apropiate `k` amintiri, după scorul aproximat.
    pub fn recall(&self, query: &[f32], k: usize) -> Result<Vec<(i64, f32)>, RecallError> {
        if query.len() != self.book.dimension {
            return Err(RecallError::DimensionDiscord);
        }
        let table = self.book.score_table(query);
        let c = self.book.centroids;
        let mut scored: Vec<(i64, f32)> = self
            .codes
            .chunks_exact(self.book.parts)
            .zip(self.ids.iter())
            .map(|(code, id)| {
                let score: f32 = code
                    .iter()
                    .enumerate()
                    .map(|(part, &x)| table[part * c + x as usize])
                    .sum();
                (*id, score)
            })
            .collect();
        top_k(&mut scored, k);
        Ok(scored)
    }
}

/// Păstrează primele `k` după scor, descrescător.
pub fn top_k(scored: &mut Vec<(i64, f32)>, k: usize) {
    let k = k.min(scored.len());
    if k == 0 {
        scored.clear();
        return;
    }
    let order = |a: &(i64, f32), b: &(i64, f32)| {
        b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)
    };
    if k < scored.len() {
        scored.select_nth_unstable_by(k - 1, order);
        scored.truncate(k);
    }
    scored.sort_by(order);
}

/// Învață tabelele cu k-means, independent pe fiecare felie.
pub fn train(
    vectors: &[f32],
    dimension: usize,
    parts: usize,
    centroids: usize,
    iterations: usize,
    seed: u64,
) -> Result<Codebook, RecallError> {
    if dimension == 0 || parts == 0 || dimension % parts != 0 {
        return Err(RecallError::DimensionDiscord);
    }
    if centroids == 0 || centroids > MAX_CENTROIDS {
        return Err(RecallError::UnboundedMemory);
    }
    if vectors.len() % dimension != 0 {
        return Err(RecallError::DimensionDiscord);
    }
    let count = vectors.len() / dimension;
    // Mai multe forme decât exemple înseamnă forme goale, adică un tabel care
    // promite o precizie pe care datele nu o pot da.
    if count < centroids {
        return Err(RecallError::UnboundedMemory);
    }

    let sub = dimension / parts;
    let mut table = vec![0.0f32; parts * centroids * sub];
    let mut rng = SplitMix(seed);

    for part in 0..parts {
        // Feliile acestei părți, adunate contiguu.
        let mut slices = Vec::with_capacity(count * sub);
        for row in vectors.chunks_exact(dimension) {
            slices.extend_from_slice(&row[part * sub..(part + 1) * sub]);
        }
        let learned = kmeans(&slices, sub, centroids, iterations, &mut rng);
        let start = part * centroids * sub;
        table[start..start + centroids * sub].copy_from_slice(&learned);
    }

    Ok(Codebook { dimension, parts, centroids, table })
}

fn encode_all(book: &Codebook, vectors: &[f32]) -> Vec<u16> {
    let rows: Vec<&[f32]> = vectors.chunks_exact(book.dimension).collect();
    let chunks = parallel_map(&rows, |row| book.encode(row));
    chunks.into_iter().flatten().collect()
}

fn nearest(book: &Codebook, part: usize, slice: &[f32]) -> usize {
    let sub = book.sub();
    let start = part * book.centroids * sub;
    let block = &book.table[start..start + book.centroids * sub];
    argmin_l2(slice, block, sub)
}

/// Indexul formei celei mai apropiate (distanță euclidiană).
fn argmin_l2(x: &[f32], block: &[f32], sub: usize) -> usize {
    let mut best = 0;
    let mut best_d = f32::INFINITY;
    for (i, c) in block.chunks_exact(sub).enumerate() {
        let d: f32 = x.iter().zip(c).map(|(a, b)| (a - b) * (a - b)).sum();
        if d < best_d {
            best_d = d;
            best = i;
        }
    }
    best
}

/// k-means clasic (Lloyd), cu inițializare din exemple distincte alese
/// aleator. O formă rămasă goală e reînsămânțată dintr-un exemplu aleator,
/// ca tabelul să nu aibă găuri.
fn kmeans(points: &[f32], sub: usize, k: usize, iterations: usize, rng: &mut SplitMix) -> Vec<f32> {
    let n = points.len() / sub;
    let mut centers = Vec::with_capacity(k * sub);
    for index in sample_distinct(n, k, rng) {
        centers.extend_from_slice(&points[index * sub..(index + 1) * sub]);
    }

    let rows: Vec<&[f32]> = points.chunks_exact(sub).collect();
    for _ in 0..iterations.max(1) {
        let assigned = parallel_map(&rows, |p| vec![argmin_l2(p, &centers, sub) as u32]);
        let mut sums = vec![0.0f64; k * sub];
        let mut counts = vec![0usize; k];
        for (p, a) in rows.iter().zip(assigned.iter()) {
            let c = a[0] as usize;
            counts[c] += 1;
            for (s, v) in sums[c * sub..(c + 1) * sub].iter_mut().zip(p.iter()) {
                *s += f64::from(*v);
            }
        }
        for c in 0..k {
            let dst = &mut centers[c * sub..(c + 1) * sub];
            if counts[c] == 0 {
                let pick = (rng.next() % n as u64) as usize;
                dst.copy_from_slice(&points[pick * sub..(pick + 1) * sub]);
            } else {
                for (d, s) in dst.iter_mut().zip(&sums[c * sub..(c + 1) * sub]) {
                    *d = (*s / counts[c] as f64) as f32;
                }
            }
        }
    }
    centers
}

fn sample_distinct(n: usize, k: usize, rng: &mut SplitMix) -> Vec<usize> {
    // Fisher-Yates parțial.
    let mut all: Vec<usize> = (0..n).collect();
    for i in 0..k {
        let j = i + (rng.next() % (n - i) as u64) as usize;
        all.swap(i, j);
    }
    all.truncate(k);
    all
}

/// Aplică `f` pe fiecare rând, împărțit pe firele disponibile. Ordinea se
/// păstrează.
fn parallel_map<T, F>(rows: &[&[f32]], f: F) -> Vec<Vec<T>>
where
    T: Send,
    F: Fn(&[f32]) -> Vec<T> + Sync,
{
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get());
    let threads = threads.max(1);
    let per = ((rows.len() + threads - 1) / threads).max(1);
    std::thread::scope(|scope| {
        let handles: Vec<_> = rows
            .chunks(per)
            .map(|chunk| scope.spawn(|| chunk.iter().map(|r| f(r)).collect::<Vec<_>>()))
            .collect();
        handles
            .into_iter()
            .flat_map(|h| h.join().unwrap_or_default())
            .collect()
    })
}

pub fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// Generator mic și determinist, ca tabelele să fie reproductibile.
pub struct SplitMix(pub u64);

impl SplitMix {
    pub fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform în [-1, 1).
    pub fn unit(&mut self) -> f32 {
        ((self.next() >> 40) as f32 / (1u64 << 24) as f32) * 2.0 - 1.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit_rows(n: usize, dim: usize, seed: u64) -> Vec<f32> {
        let mut rng = SplitMix(seed);
        let mut out = Vec::with_capacity(n * dim);
        for _ in 0..n {
            let row: Vec<f32> = (0..dim).map(|_| rng.unit()).collect();
            let norm = dot(&row, &row).sqrt();
            out.extend(row.iter().map(|v| v / norm));
        }
        out
    }

    #[test]
    fn felii_inegale_sunt_refuzate() {
        let v = unit_rows(10, 10, 1);
        assert_eq!(train(&v, 10, 4, 2, 2, 1).unwrap_err(), RecallError::DimensionDiscord);
    }

    #[test]
    fn mai_multe_forme_decat_exemple_e_refuzat() {
        let v = unit_rows(5, 8, 1);
        assert_eq!(train(&v, 8, 2, 6, 2, 1).unwrap_err(), RecallError::UnboundedMemory);
    }

    #[test]
    fn codul_are_o_parte_pe_felie_si_incape_in_tabel() {
        let v = unit_rows(300, 16, 2);
        let m = CodedMemory::build(&v, &(0..300).collect::<Vec<_>>(), 16, 4, 16, 5, 7).unwrap();
        for i in 0..300 {
            let code = m.code(i).unwrap();
            assert_eq!(code.len(), 4);
            assert!(code.iter().all(|&c| (c as usize) < 16));
        }
        assert_eq!(m.book.code_bytes(), 4);
    }

    /// Cu atâtea forme câte exemple, fiecare exemplu își are propria formă și
    /// reconstrucția e (aproape) exactă.
    #[test]
    fn tabelul_complet_reconstruieste_exact() {
        let v = unit_rows(32, 8, 3);
        let book = train(&v, 8, 2, 32, 10, 3).unwrap();
        for row in v.chunks_exact(8) {
            let back = book.decode(&book.encode(row));
            let err: f32 = row.iter().zip(&back).map(|(a, b)| (a - b).abs()).sum();
            assert!(err < 1e-4, "eroare {err}");
        }
    }

    /// Scorul din tabel e identic cu produsul scalar pe vectorul reconstruit.
    #[test]
    fn scorul_din_tabel_e_produsul_scalar_reconstruit() {
        let v = unit_rows(200, 12, 4);
        let m = CodedMemory::build(&v, &(0..200).collect::<Vec<_>>(), 12, 3, 8, 4, 9).unwrap();
        let q = &v[0..12];
        let found = m.recall(q, 200).unwrap();
        for (id, score) in found {
            let back = m.book.decode(m.code(id as usize).unwrap());
            assert!((dot(q, &back) - score).abs() < 1e-4);
        }
    }

    #[test]
    fn intrebarea_isi_gaseste_propria_amintire() {
        let v = unit_rows(64, 8, 5);
        let m = CodedMemory::build(&v, &(100..164).collect::<Vec<_>>(), 8, 2, 64, 10, 5).unwrap();
        let found = m.recall(&v[8 * 7..8 * 8], 1).unwrap();
        assert_eq!(found[0].0, 107);
        assert_eq!(m.code_of(107), m.code(7));
        assert_eq!(m.code_of(999), None);
    }

    #[test]
    fn peste_256_de_forme_codul_are_doi_octeti_pe_parte() {
        let v = unit_rows(600, 8, 6);
        let book = train(&v, 8, 2, 300, 1, 1).unwrap();
        assert_eq!(book.code_bytes(), 4);
        assert_eq!(book.table_bytes(), 2 * 300 * 4 * 4);
    }

    #[test]
    fn top_k_ordoneaza_si_taie() {
        let mut s = vec![(1, 0.1), (2, 0.9), (3, 0.5), (4, 0.7)];
        top_k(&mut s, 2);
        assert_eq!(s, vec![(2, 0.9), (4, 0.7)]);
        let mut e: Vec<(i64, f32)> = vec![];
        top_k(&mut e, 3);
        assert!(e.is_empty());
    }
}
