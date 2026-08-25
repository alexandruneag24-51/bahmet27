//! # `bahmet_vault` — Umbra care ține cheile
//!
//! Jumătatea de Apă a sistemului. Aici trăiesc secretele, și de aici nu ies.
//!
//! ## Contractul acestui modul
//!
//! **Nu există nicio funcție care întoarce material de cheie.** Caută în tot
//! fișierul: nu găsești `export_key`, `key_bytes`, `reveal` sau `dump`.
//! Absența lor nu e o omisiune — este mecanismul de securitate.
//!
//! Motivul e specific BEAM: binarele Erlang peste 64 de octeți sunt numărate
//! prin referințe, copiate liber între procese și colectate nedeterminist.
//! **Nu poți șterge sigur un binar Erlang din memorie.** Aici, `Drop` e
//! determinist și `Zeroizing` scrie zerouri volatile pe care optimizatorul nu
//! le poate elimina.
//!
//! ## Structura: miez pur, coajă subțire
//!
//! Toată logica criptografică trăiește în funcții care întorc
//! `Result<_, VaultError>` — tipuri Rust obișnuite, fără nicio urmă de rustler.
//! Atomii Erlang apar exclusiv la frontieră, în funcțiile `#[rustler::nif]`.
//!
//! Separarea nu e cosmetică. Construirea unui atom cere `enif_make_atom`, adică
//! mașina virtuală pornită; orice logică amestecată cu atomi devine imposibil
//! de testat cu `cargo test`. Iar codul criptografic care nu poate fi testat
//! în izolare, în practică, nu e testat deloc.
//!
//! ## Ce NU face
//!
//! Nu implementează nicio primitivă. AES, ChaCha20 și Poly1305 vin din
//! crate-uri auditate. Nu e validat FIPS. Nu e auditat. Vezi CRYPTO.md.

use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    XChaCha20Poly1305, XNonce,
};
use rand_core::{OsRng, RngCore};
use rustler::{Atom, Binary, Env, NifResult, OwnedBinary, Resource, ResourceArc};
use sha2::{Digest, Sha256};
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 24; // XChaCha20: 192 biți — vezi `seal_bytes`
const TAG_BYTES: usize = 16; // Poly1305

// ═══════════════════════════════════════════════════════════════════════
//  EROAREA — pură, testabilă, fără mașină virtuală
// ═══════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VaultError {
    /// UN SINGUR mod de eșec la desfacere.
    ///
    /// Cheie greșită, ciphertext modificat, AAD nepotrivit, lungime invalidă —
    /// toate întorc asta. Erori distincte ar forma un oracol: un atacator ar
    /// interoga sistemul până ar afla care parte a ghicit-o corect.
    /// Ambiguitatea de aici este o funcție, nu o scăpare.
    DecryptFailed,
    /// Erori de programare, nu de securitate. Pot fi distincte fără risc.
    BadKeyLength,
    EntropyUnavailable,
    AllocationFailed,
    KeyDestroyed,
}

mod atoms {
    rustler::atoms! {
        ok,
        decrypt_failed,
        bad_key_length,
        entropy_unavailable,
        allocation_failed,
        key_destroyed,
    }
}

impl VaultError {
    /// Singurul loc din modul care atinge tabela de atomi. Se apelează numai
    /// dinspre `#[rustler::nif]`, deci numai când BEAM e viu.
    fn as_atom(self) -> Atom {
        match self {
            Self::DecryptFailed => atoms::decrypt_failed(),
            Self::BadKeyLength => atoms::bad_key_length(),
            Self::EntropyUnavailable => atoms::entropy_unavailable(),
            Self::AllocationFailed => atoms::allocation_failed(),
            Self::KeyDestroyed => atoms::key_destroyed(),
        }
    }
}

/// Conversia la frontieră. Datorită ei, `?` funcționează direct în NIF-uri,
/// iar miezul rămâne curat.
impl From<VaultError> for rustler::Error {
    fn from(error: VaultError) -> Self {
        rustler::Error::Term(Box::new(error.as_atom()))
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CHEIA
// ═══════════════════════════════════════════════════════════════════════

/// O cheie sub custodie.
///
/// `Zeroizing<[u8; 32]>` garantează ștergerea la `Drop` — nu un `memset`
/// obișnuit, ci scrieri volatile plus o barieră de compilator. Fără asta, LLVM
/// are dreptul să elimine o scriere într-o zonă care urmează să fie eliberată,
/// iar ștergerea ar dispărea tăcut la `--release`: un bug care nu apare
/// niciodată în debug.
///
/// `material` e privat și nu are accesor. Perfecționismul apare aici ca
/// absență, nu ca verificare.
pub struct KeyHandle {
    material: Zeroizing<[u8; KEY_BYTES]>,
    /// Amprentă publică: SHA-256 peste un domeniu de separare plus cheia,
    /// trunchiat la 8 octeți. Spune *care* cheie, niciodată *ce* cheie.
    fingerprint: [u8; 8],
    generation: u32,
    uses: AtomicU64,
    destroyed: AtomicBool,
}

#[rustler::resource_impl]
impl Resource for KeyHandle {}

/// Geamănul în Rust al lui `format_status/1` din Erlang.
///
/// Fără el, un `dbg!`, un mesaj de panică sau un backtrace ar tipări cheia.
/// Integritatea care acoperă o singură ieșire nu e integritate.
impl fmt::Debug for KeyHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KeyHandle")
            .field("fingerprint", &self.fingerprint)
            .field("generation", &self.generation)
            .field("destroyed", &self.destroyed.load(Ordering::Relaxed))
            .field("material", &"[redactat]")
            .finish()
    }
}

impl KeyHandle {
    /// Preia materialul **și îl șterge din tamponul apelantului**.
    ///
    /// Primim `&mut` tocmai ca ștergerea sursei să nu fie opțională. Un
    /// `[u8; 32]` e `Copy`; dacă l-am primi prin valoare, copia apelantului ar
    /// rămâne în stivă, în afara controlului nostru.
    fn from_material(material: &mut [u8; KEY_BYTES], generation: u32) -> Self {
        // Domeniu de separare: fără el, amprenta ar fi un hash direct al cheii.
        let mut hasher = Sha256::new();
        hasher.update(b"bahmet27/key-fingerprint/v1");
        hasher.update(&material[..]);
        let digest = hasher.finalize();

        let mut fingerprint = [0u8; 8];
        fingerprint.copy_from_slice(&digest[..8]);

        let handle = Self {
            material: Zeroizing::new(*material),
            fingerprint,
            generation,
            uses: AtomicU64::new(0),
            destroyed: AtomicBool::new(false),
        };

        material.zeroize();
        handle
    }

    fn cipher(&self) -> Result<XChaCha20Poly1305, VaultError> {
        if self.destroyed.load(Ordering::Relaxed) {
            return Err(VaultError::KeyDestroyed);
        }
        XChaCha20Poly1305::new_from_slice(self.material.as_ref())
            .map_err(|_| VaultError::BadKeyLength)
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  MIEZUL PUR
// ═══════════════════════════════════════════════════════════════════════

/// CSPRNG-ul sistemului: `getrandom(2)` / `BCryptGenRandom`.
///
/// Kernelul amestecă deja RDRAND, jitter de întreruperi și zgomot hardware.
/// Ce NU facem, deliberat: rezervoare proprii de entropie, RDRAND direct,
/// amestecare cu timestamp-uri. Fiecare dintre acestea a produs vulnerabilități
/// reale în sisteme reale.
fn fill_entropy(buffer: &mut [u8]) -> Result<(), VaultError> {
    OsRng
        .try_fill_bytes(buffer)
        .map_err(|_| VaultError::EntropyUnavailable)
}

/// Detectează doar cazul catastrofal: sursă indisponibilă sau blocată.
/// Nu e un test statistic — acelea nu pot valida un CSPRNG oricum.
fn entropy_is_healthy() -> Result<bool, VaultError> {
    let mut first = Zeroizing::new([0u8; 32]);
    let mut second = Zeroizing::new([0u8; 32]);
    fill_entropy(first.as_mut())?;
    fill_entropy(second.as_mut())?;

    // Timp constant din obișnuință, deși aici nu e secret. Obiceiul e mai
    // sigur decât judecata caz cu caz.
    let identical: bool = first.ct_eq(second.as_ref()).into();
    let all_zero: bool = first.ct_eq(&[0u8; 32]).into();

    Ok(!identical && !all_zero)
}

fn generate_key(generation: u32) -> Result<KeyHandle, VaultError> {
    let mut material = [0u8; KEY_BYTES];
    fill_entropy(&mut material)?;
    Ok(KeyHandle::from_material(&mut material, generation))
}

/// Sigilează. Întoarce `nonce ‖ ciphertext ‖ tag`.
///
/// **De ce XChaCha20 și nu AES-GCM implicit.** Nonce-ul de 192 de biți e
/// întreaga miză. Cu 96 de biți și nonce-uri aleatoare, riscul de coliziune
/// devine real după ~2³² mesaje pe aceeași cheie — iar o coliziune de nonce la
/// GCM e catastrofală: pierzi confidențialitatea *și* permiți recuperarea cheii
/// de autentificare.
///
/// Cu 192 de biți, coliziunile nu se întâmplă în practică. Am eliminat o clasă
/// întreagă de greșeli prin alegerea cifrului, nu prin disciplina
/// programatorului. Contoarele de nonce sunt speranță; asta e proiectare.
fn seal_bytes(key: &KeyHandle, plaintext: &[u8], aad: &[u8]) -> Result<Vec<u8>, VaultError> {
    let cipher = key.cipher()?;

    let mut nonce_bytes = [0u8; NONCE_BYTES];
    fill_entropy(&mut nonce_bytes)?;
    let nonce = XNonce::from_slice(&nonce_bytes);

    let body = cipher
        .encrypt(nonce, Payload { msg: plaintext, aad })
        .map_err(|_| VaultError::DecryptFailed)?;

    key.uses.fetch_add(1, Ordering::Relaxed);

    let mut framed = Vec::with_capacity(NONCE_BYTES + body.len());
    framed.extend_from_slice(&nonce_bytes);
    framed.extend_from_slice(&body);
    Ok(framed)
}

/// Desface. Verificarea tag-ului se face în timp constant, în interiorul
/// crate-ului; noi adăugăm garanția că nu distingem între cauze.
fn unseal_bytes(key: &KeyHandle, sealed: &[u8], aad: &[u8]) -> Result<Vec<u8>, VaultError> {
    let cipher = key.cipher()?;

    // Lungime insuficientă: tot `DecryptFailed`, deși e clar o eroare de format.
    // Nu oferim nici măcar informația „ai nimerit lungimea corectă".
    if sealed.len() < NONCE_BYTES + TAG_BYTES {
        return Err(VaultError::DecryptFailed);
    }

    let (nonce_bytes, body) = sealed.split_at(NONCE_BYTES);
    let nonce = XNonce::from_slice(nonce_bytes);

    let plain = cipher
        .decrypt(nonce, Payload { msg: body, aad })
        .map_err(|_| VaultError::DecryptFailed)?;

    key.uses.fetch_add(1, Ordering::Relaxed);
    Ok(plain)
}

/// Cifrare cu plic: KEK-ul împachetează DEK-ul pentru stocare.
///
/// Rotația devine reîmpachetarea DEK-urilor — kilobytes, nu terabytes. Datele
/// în vrac nu se ating niciodată.
fn wrap_bytes(kek: &KeyHandle, dek: &KeyHandle, aad: &[u8]) -> Result<Vec<u8>, VaultError> {
    if dek.destroyed.load(Ordering::Relaxed) {
        return Err(VaultError::KeyDestroyed);
    }
    // Singurul loc unde materialul unei chei e citit ca octeți — și chiar și
    // aici merge direct în cifru, nu spre apelant.
    seal_bytes(kek, dek.material.as_ref(), aad)
}

fn unwrap_bytes(kek: &KeyHandle, wrapped: &[u8], aad: &[u8]) -> Result<[u8; KEY_BYTES], VaultError> {
    let mut plain = unseal_bytes(kek, wrapped, aad)?;

    if plain.len() != KEY_BYTES {
        plain.zeroize();
        return Err(VaultError::BadKeyLength);
    }

    let mut material = [0u8; KEY_BYTES];
    material.copy_from_slice(&plain);
    plain.zeroize();
    Ok(material)
}

// ═══════════════════════════════════════════════════════════════════════
//  COAJA — NIF-uri subțiri, singurul loc cu atomi
// ═══════════════════════════════════════════════════════════════════════

#[rustler::nif]
fn entropy_health() -> NifResult<(Atom, bool)> {
    Ok((atoms::ok(), entropy_is_healthy()?))
}

#[rustler::nif]
fn forge_key(generation: u32) -> NifResult<ResourceArc<KeyHandle>> {
    Ok(ResourceArc::new(generate_key(generation)?))
}

#[rustler::nif]
fn fingerprint<'a>(env: Env<'a>, key: ResourceArc<KeyHandle>) -> NifResult<Binary<'a>> {
    Ok(into_binary(env, &key.fingerprint)?)
}

#[derive(rustler::NifMap)]
struct KeyStatus {
    generation: u32,
    uses: u64,
    destroyed: bool,
}

#[rustler::nif]
fn key_status(key: ResourceArc<KeyHandle>) -> KeyStatus {
    KeyStatus {
        generation: key.generation,
        uses: key.uses.load(Ordering::Relaxed),
        destroyed: key.destroyed.load(Ordering::Relaxed),
    }
}

/// Crypto-shredding. Distrugi cheia, datele devin zgomot fără a atinge un
/// octet din ele — singura ștergere care funcționează peste backup-uri,
/// replici și wear-leveling. „Uită-mă" devenit executabil.
///
/// Ștergerea fizică a octeților se face la `Drop`, când ultimul deținător
/// Erlang îi dă drumul; nu putem mai devreme, fiindcă `ResourceArc` e partajat.
#[rustler::nif]
fn shred(key: ResourceArc<KeyHandle>) -> Atom {
    key.destroyed.store(true, Ordering::SeqCst);
    atoms::ok()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn seal<'a>(
    env: Env<'a>,
    key: ResourceArc<KeyHandle>,
    plaintext: Binary<'a>,
    aad: Binary<'a>,
) -> NifResult<(Atom, Binary<'a>)> {
    let mut framed = seal_bytes(&key, plaintext.as_slice(), aad.as_slice())?;
    let out = into_binary(env, &framed)?;
    framed.zeroize();
    Ok((atoms::ok(), out))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn unseal<'a>(
    env: Env<'a>,
    key: ResourceArc<KeyHandle>,
    sealed: Binary<'a>,
    aad: Binary<'a>,
) -> NifResult<(Atom, Binary<'a>)> {
    let mut plain = unseal_bytes(&key, sealed.as_slice(), aad.as_slice())?;
    let out = into_binary(env, &plain)?;
    // Ștergem copia noastră. Cea care pleacă spre BEAM scapă de sub control —
    // vezi CRYPTO.md §1. Facem ce putem, unde putem.
    plain.zeroize();
    Ok((atoms::ok(), out))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn wrap_key<'a>(
    env: Env<'a>,
    kek: ResourceArc<KeyHandle>,
    dek: ResourceArc<KeyHandle>,
    aad: Binary<'a>,
) -> NifResult<(Atom, Binary<'a>)> {
    let mut wrapped = wrap_bytes(&kek, &dek, aad.as_slice())?;
    let out = into_binary(env, &wrapped)?;
    wrapped.zeroize();
    Ok((atoms::ok(), out))
}

/// Materialul nu devine niciodată termen Erlang: iese din plic direct într-un
/// `KeyHandle`. Frontiera de custodie ține și la desfacere.
#[rustler::nif(schedule = "DirtyCpu")]
fn unwrap_key<'a>(
    kek: ResourceArc<KeyHandle>,
    wrapped: Binary<'a>,
    aad: Binary<'a>,
    generation: u32,
) -> NifResult<ResourceArc<KeyHandle>> {
    let mut material = unwrap_bytes(&kek, wrapped.as_slice(), aad.as_slice())?;
    let handle = KeyHandle::from_material(&mut material, generation);
    Ok(ResourceArc::new(handle))
}

fn into_binary<'a>(env: Env<'a>, data: &[u8]) -> Result<Binary<'a>, VaultError> {
    let mut owned = OwnedBinary::new(data.len()).ok_or(VaultError::AllocationFailed)?;
    owned.as_mut_slice().copy_from_slice(data);
    Ok(owned.release(env))
}

rustler::init!("bahmet_vault");

// ═══════════════════════════════════════════════════════════════════════
//  PROBE — pe funcțiile reale, fără mașină virtuală
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn key(generation: u32) -> KeyHandle {
        let mut material = [0u8; KEY_BYTES];
        OsRng.fill_bytes(&mut material);
        KeyHandle::from_material(&mut material, generation)
    }

    #[test]
    fn sigilarea_si_desfacerea_se_inchid() {
        let k = key(1);
        let msg = b"secret care nu trebuie sa iasa";
        let sealed = seal_bytes(&k, msg, b"context").expect("sigilare");
        let plain = unseal_bytes(&k, &sealed, b"context").expect("desfacere");
        assert_eq!(&plain[..], &msg[..]);
    }

    /// Cea mai importantă probă din fișier.
    ///
    /// Dacă aceleași date cifrate de două ori produc același ciphertext,
    /// cifrarea e deterministă: un atacator vede care mesaje se repetă,
    /// construiește un dicționar și sparge sistemul fără să atingă cheia.
    #[test]
    fn nonce_proaspat_la_fiecare_sigilare() {
        let k = key(1);
        let first = seal_bytes(&k, b"identic", b"").expect("prima");
        let second = seal_bytes(&k, b"identic", b"").expect("a doua");
        assert_ne!(first, second, "cifrare determinista");
        assert_eq!(&unseal_bytes(&k, &first, b"").unwrap()[..], &b"identic"[..]);
        assert_eq!(&unseal_bytes(&k, &second, b"").unwrap()[..], &b"identic"[..]);
    }

    #[test]
    fn incadrarea_are_nonce_si_tag() {
        let k = key(1);
        let sealed = seal_bytes(&k, b"x", b"").unwrap();
        assert_eq!(sealed.len(), NONCE_BYTES + 1 + TAG_BYTES);
    }

    #[test]
    fn contextul_gresit_refuza() {
        let k = key(1);
        let sealed = seal_bytes(&k, b"date", b"corect").unwrap();
        assert_eq!(
            unseal_bytes(&k, &sealed, b"gresit"),
            Err(VaultError::DecryptFailed)
        );
    }

    #[test]
    fn un_bit_schimbat_refuza() {
        let k = key(1);
        let mut sealed = seal_bytes(&k, b"date", b"").unwrap();
        let last = sealed.len() - 1;
        sealed[last] ^= 0x01;
        assert_eq!(unseal_bytes(&k, &sealed, b""), Err(VaultError::DecryptFailed));
    }

    #[test]
    fn cheia_gresita_refuza() {
        let a = key(1);
        let b = key(2);
        let sealed = seal_bytes(&a, b"date", b"").unwrap();
        assert_eq!(unseal_bytes(&b, &sealed, b""), Err(VaultError::DecryptFailed));
    }

    /// Trei cauze complet diferite, același atom. Diferența ar fi un oracol.
    #[test]
    fn un_singur_mod_de_esec() {
        let k1 = key(1);
        let k2 = key(2);
        let sealed = seal_bytes(&k1, b"date", b"aad").unwrap();

        let wrong_aad = unseal_bytes(&k1, &sealed, b"alt").unwrap_err();
        let wrong_key = unseal_bytes(&k2, &sealed, b"aad").unwrap_err();
        let malformed = unseal_bytes(&k1, &[0u8; 8], b"aad").unwrap_err();

        assert_eq!(wrong_aad, wrong_key);
        assert_eq!(wrong_key, malformed);
        assert_eq!(wrong_aad, VaultError::DecryptFailed);
    }

    #[test]
    fn cheia_distrusa_refuza_orice() {
        let k = key(1);
        let sealed = seal_bytes(&k, b"date", b"").unwrap();
        k.destroyed.store(true, Ordering::SeqCst);
        assert_eq!(unseal_bytes(&k, &sealed, b""), Err(VaultError::KeyDestroyed));
        assert_eq!(seal_bytes(&k, b"altceva", b""), Err(VaultError::KeyDestroyed));
    }

    #[test]
    fn plicul_se_inchide() {
        let kek = key(0);
        let dek = key(1);
        let payload = b"un terabyte, simbolic";

        let sealed = seal_bytes(&dek, payload, b"").unwrap();
        let wrapped = wrap_bytes(&kek, &dek, b"realm").unwrap();

        let mut material = unwrap_bytes(&kek, &wrapped, b"realm").unwrap();
        let restored = KeyHandle::from_material(&mut material, 1);

        assert_eq!(
            &unseal_bytes(&restored, &sealed, b"").unwrap()[..],
            &payload[..]
        );
        assert_eq!(restored.fingerprint, dek.fingerprint, "aceeasi cheie");
    }

    #[test]
    fn plicul_refuza_alt_realm() {
        let kek = key(0);
        let dek = key(1);
        let wrapped = wrap_bytes(&kek, &dek, b"realm-a").unwrap();
        assert_eq!(
            unwrap_bytes(&kek, &wrapped, b"realm-b"),
            Err(VaultError::DecryptFailed)
        );
    }

    #[test]
    fn amprentele_difera_si_sunt_stabile() {
        let a = key(1);
        let b = key(1);
        assert_ne!(a.fingerprint, b.fingerprint);
        assert_eq!(a.fingerprint, a.fingerprint);
    }

    #[test]
    fn entropia_e_sanatoasa() {
        assert!(entropy_is_healthy().expect("sursa disponibila"));
    }

    /// `Debug` nu are voie să scoată materialul — geamănul lui `format_status/1`.
    #[test]
    fn debug_nu_dezvaluie_cheia() {
        let k = key(1);
        let printed = format!("{:?}", k);
        assert!(printed.contains("redactat"));
    }
}
