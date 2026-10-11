//! Măsurătoarea: memoria comprimată față de vectorii întregi.
//!
//! ```bash
//! cargo run --release --example pq_bench                 # date sintetice
//! cargo run --release --example pq_bench -- memorie.bhm1 # o memorie reală
//! ```
//!
//! O memorie reală se scoate din shell cu
//! `file:write_file("memorie.bhm1", bahmet_recall:snapshot(M))`.
//!
//! Pentru fiecare variantă tipărește: memoria ocupată, timpul de învățare,
//! timpul mediu per întrebare și cât de des găsește aceiași vecini ca
//! căutarea exactă.

use bahmet_recall::pq::{dot, top_k, CodedMemory, SplitMix};
use std::time::Instant;

const QUERIES: usize = 200;
const K: usize = 10;

fn main() {
    let (dimension, vectors, queries, source) = match std::env::args().nth(1) {
        Some(path) => load(&path),
        None => synthetic(20_000, 768),
    };
    let count = vectors.len() / dimension;
    let ids: Vec<i64> = (0..count as i64).collect();
    println!("Date: {source} -- {count} amintiri x {dimension} dimensiuni, {} intrebari\n", queries.len());

    // Adevărul: căutarea exactă, vector cu vector.
    let started = Instant::now();
    let truth: Vec<Vec<i64>> = queries.iter().map(|q| exact(&vectors, dimension, q, K)).collect();
    let exact_ms = started.elapsed().as_secs_f64() * 1000.0 / queries.len() as f64;
    let full_bytes = count * dimension * 4;

    println!(
        "{:<26} {:>12} {:>10} {:>12} {:>10} {:>12}",
        "varianta", "memorie", "invatare", "/intrebare", "recall@10", "10 in top100"
    );
    println!(
        "{:<26} {:>12} {:>10} {:>9.3} ms {:>10} {:>12}",
        "vectori intregi (exact)", human(full_bytes), "-", exact_ms, "100.0%", "100.0%"
    );

    for (parts, centroids, iterations) in [(4, 256, 10), (4, 10_000, 6), (16, 256, 10)] {
        let started = Instant::now();
        let coded = match CodedMemory::build(&vectors, &ids, dimension, parts, centroids, iterations, 27) {
            Ok(c) => c,
            Err(e) => {
                println!("{parts} parti x {centroids}: nu se poate ({e:?})");
                continue;
            }
        };
        let train_s = started.elapsed().as_secs_f64();

        let started = Instant::now();
        let found: Vec<Vec<i64>> = queries
            .iter()
            .map(|q| coded.recall(q, 100).unwrap_or_default().into_iter().map(|(id, _)| id).collect())
            .collect();
        let query_ms = started.elapsed().as_secs_f64() * 1000.0 / queries.len() as f64;

        let at10 = overlap(&truth, &found, K);
        let at100 = overlap(&truth, &found, 100);
        println!(
            "{:<26} {:>12} {:>8.1} s {:>9.3} ms {:>9.1}% {:>11.1}%",
            format!("{parts} parti x {centroids} forme"),
            human(coded.bytes()),
            train_s,
            query_ms,
            at10 * 100.0,
            at100 * 100.0
        );

        // Lista scurta din coduri, apoi reordonare exacta a primilor 100 cu
        // vectorii intregi (care pot sta pe disc, nu in RAM).
        let started = Instant::now();
        let reranked: Vec<Vec<i64>> = queries
            .iter()
            .zip(&found)
            .map(|(q, short)| {
                let mut scored: Vec<(i64, f32)> = short
                    .iter()
                    .map(|&id| {
                        let row = &vectors[id as usize * dimension..(id as usize + 1) * dimension];
                        (id, dot(row, q))
                    })
                    .collect();
                top_k(&mut scored, K);
                scored.into_iter().map(|(id, _)| id).collect()
            })
            .collect();
        let rerank_ms = query_ms + started.elapsed().as_secs_f64() * 1000.0 / queries.len() as f64;
        println!(
            "{:<26} {:>12} {:>10} {:>9.3} ms {:>9.1}% {:>12}",
            "  + reordonare exacta",
            "+ vectori",
            "-",
            rerank_ms,
            overlap(&truth, &reranked, K) * 100.0,
            "-"
        );
    }
    println!("\nrecall@10: din cei 10 vecini adevarati, cati sunt si in primii 10 gasiti.");
    println!("10 in top100: cati dintre cei 10 adevarati sunt in primii 100 gasiti (rerank posibil).");
}

fn exact(vectors: &[f32], dimension: usize, q: &[f32], k: usize) -> Vec<i64> {
    let mut scored: Vec<(i64, f32)> = vectors
        .chunks_exact(dimension)
        .enumerate()
        .map(|(i, row)| (i as i64, dot(row, q)))
        .collect();
    top_k(&mut scored, k);
    scored.into_iter().map(|(id, _)| id).collect()
}

fn overlap(truth: &[Vec<i64>], found: &[Vec<i64>], depth: usize) -> f64 {
    let mut hit = 0usize;
    let mut total = 0usize;
    for (t, f) in truth.iter().zip(found) {
        let window = &f[..depth.min(f.len())];
        hit += t.iter().filter(|id| window.contains(id)).count();
        total += t.len();
    }
    hit as f64 / total.max(1) as f64
}

fn normalize(v: &mut [f32]) {
    let n = dot(v, v).sqrt();
    v.iter_mut().for_each(|x| *x /= n);
}

/// Vectori grupați pe teme și subteme, ca embedding-urile reale: textele
/// despre același subiect stau aproape unele de altele.
fn synthetic(count: usize, dimension: usize) -> (usize, Vec<f32>, Vec<Vec<f32>>, String) {
    let mut rng = SplitMix(2710);
    let (topics, subtopics) = (64, 16);
    let random = |rng: &mut SplitMix| -> Vec<f32> {
        let mut v: Vec<f32> = (0..dimension).map(|_| rng.unit()).collect();
        normalize(&mut v);
        v
    };
    let centers: Vec<Vec<f32>> = (0..topics).map(|_| random(&mut rng)).collect();
    let subs: Vec<Vec<f32>> = (0..topics * subtopics).map(|_| random(&mut rng)).collect();

    let one = |rng: &mut SplitMix| -> Vec<f32> {
        let t = (rng.next() % topics as u64) as usize;
        let s = (rng.next() % subtopics as u64) as usize;
        let noise = random(rng);
        let mut v: Vec<f32> = (0..dimension)
            .map(|i| centers[t][i] + 0.8 * subs[t * subtopics + s][i] + 0.6 * noise[i])
            .collect();
        normalize(&mut v);
        v
    };
    let vectors: Vec<f32> = (0..count).flat_map(|_| one(&mut rng)).collect();
    let queries: Vec<Vec<f32>> = (0..QUERIES).map(|_| one(&mut rng)).collect();
    (dimension, vectors, queries, "sintetice (64 teme x 16 subteme)".into())
}

/// Citește un instantaneu `BHM1` (vezi `snapshot_bytes` din `lib.rs`).
/// Întrebările sunt primele amintiri, ușor perturbate.
fn load(path: &str) -> (usize, Vec<f32>, Vec<Vec<f32>>, String) {
    let blob = std::fs::read(path).expect("nu pot citi fisierul");
    assert_eq!(&blob[0..4], b"BHM1", "nu e un instantaneu BHM1");
    let dimension = u32::from_be_bytes(blob[4..8].try_into().unwrap()) as usize;
    let mut vectors = Vec::new();
    for entry in blob[16..].chunks_exact(8 + dimension * 4) {
        for q in entry[8..].chunks_exact(4) {
            vectors.push(f32::from_be_bytes(q.try_into().unwrap()));
        }
    }
    let mut rng = SplitMix(1);
    let queries = vectors
        .chunks_exact(dimension)
        .take(QUERIES)
        .map(|row| {
            let mut q: Vec<f32> = row.iter().map(|x| x + 0.02 * rng.unit()).collect();
            normalize(&mut q);
            q
        })
        .collect();
    (dimension, vectors, queries, path.to_string())
}

fn human(bytes: usize) -> String {
    if bytes >= 1 << 20 {
        format!("{:.1} MB", bytes as f64 / (1 << 20) as f64)
    } else {
        format!("{:.0} KB", bytes as f64 / 1024.0)
    }
}
