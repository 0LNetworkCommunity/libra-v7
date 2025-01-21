// Copyright (c) The Diem Core Contributors
// SPDX-License-Identifier: Apache-2.0

//! This module defines traits and implementations of
//! [cryptographic hash functions](https://en.wikipedia.org/wiki/Cryptographic_hash_function)
//! for the Diem project.
//!
//! It is designed to help authors protect against two types of real world attacks:
//!
//! 1. **Semantic Ambiguity**: imagine that Alice has a private key and is using
//!    two different applications, X and Y. X asks Alice to sign a message saying
//!    "I am Alice". Alice accepts to sign this message in the context of X. However,
//!    unbeknownst to Alice, in application Y, messages beginning with the letter "I"
//!    represent transfers. " am " represents a transfer of 500 coins and "Alice"
//!    can be interpreted as a destination address. When Alice signed the message she
//!    needed to be aware of how other applications might interpret that message.
//!
//! 2. **Format Ambiguity**: imagine a program that hashes a pair of strings.
//!    To hash the strings `a` and `b` it hashes `a + "||" + b`. The pair of
//!    strings `a="foo||", b = "bar"` and `a="foo", b = "||bar"` result in the
//!    same input to the hash function and therefore the same hash. This
//!    creates a collision.
//!
//! Regarding (1), this library makes it easy for Diem developers to create as
//! many new "hashable" Rust types as needed so that each Rust type hashed and signed
//! in Diem has a unique meaning, that is, unambiguously captures the intent of a signer.
//!
//! Regarding (2), this library provides the `CryptoHasher` abstraction to easily manage
//! cryptographic seeds for hashing. Hashing seeds aim to ensure that
//! the hashes of values of a given type `MyNewStruct` never collide with hashes of values
//! from another type.
//!
//! Finally, to prevent format ambiguity within a same type `MyNewStruct` and facilitate protocol
//! specifications, we use [Binary Canonical Serialization (BCS)](https://docs.rs/bcs/)
//! as the recommended solution to write Rust values into a hasher.
//!
//! # Quick Start
//!
//! To obtain a `hash()` method for any new type `MyNewStruct`, it is (strongly) recommended to
//! use the derive macros of `serde` and `diem_crypto_derive` as follows:
//! ```
//! use diem_crypto::hash::CryptoHash;
//! use diem_crypto_derive::{CryptoHasher, BCSCryptoHash};
//! use serde::{Deserialize, Serialize};
//! #[derive(Serialize, Deserialize, CryptoHasher, BCSCryptoHash)]
//! struct MyNewStruct { /*...*/ }
//!
//! let value = MyNewStruct { /*...*/ };
//! value.hash();
//! ```
//!
//! Under the hood, this will generate a new implementation `MyNewStructHasher` for the trait
//! `CryptoHasher` and implement the trait `CryptoHash` for `MyNewStruct` using BCS.
//!
//! # Implementing New Hashers
//!
//! The trait `CryptoHasher` captures the notion of a pre-seeded hash function, aka a "hasher".
//! New implementations can be defined in two ways.
//!
//! ## Derive macro (recommended)
//!
//! For any new structure `MyNewStruct` that needs to be hashed, it is recommended to simply
//! use the derive macro [`CryptoHasher`](https://doc.rust-lang.org/reference/procedural-macros.html).
//!
//! ```
//! use diem_crypto_derive::CryptoHasher;
//! use serde::Deserialize;
//! #[derive(Deserialize, CryptoHasher)]
//! #[serde(rename = "OptionalCustomSerdeName")]
//! struct MyNewStruct { /*...*/ }
//! ```
//!
//! The macro `CryptoHasher` will define a hasher automatically called `MyNewStructHasher`, and derive a salt
//! using the name of the type as seen by the Serde library. In the example above, this name
//! was changed using the Serde parameter `rename`: the salt will be based on the value `OptionalCustomSerdeName`
//! instead of the default name `MyNewStruct`.
//!
//! ## Customized hashers
//!
//! **IMPORTANT:** Do NOT use this for new code unless you know what you are doing.
//!
//! This library also provides a few customized hashers defined in the code as follows:
//!
//! ```
//! # // To get around that there's no way to doc-test a non-exported macro:
//! # macro_rules! define_hasher { ($e:expr) => () }
//! define_hasher! { (MyNewDataHasher, MY_NEW_DATA_HASHER, MY_NEW_DATA_SEED, b"MyUniqueSaltString") }
//! ```
//!
//! # Using a hasher directly
//!
//! **IMPORTANT:** Do NOT use this for new code unless you know what you are doing.
//!
//! ```
//! use diem_crypto::hash::{CryptoHasher, TestOnlyHasher};
//!
//! let mut hasher = TestOnlyHasher::default();
//! hasher.update("Test message".as_bytes());
//! let hash_value = hasher.finish();
//! ```
#![allow(clippy::arithmetic_side_effects)]
use bytes::Bytes;
use hex::FromHex;
// use mirai_annotations::*;
// use once_cell::sync::{Lazy, OnceCell};

use rand::{rngs::OsRng, Rng};
use serde::{de, ser};
use std::{
    self,
    convert::{AsRef, TryFrom},
    fmt,
    str::FromStr,
};
use tiny_keccak::{Hasher, Sha3};

/// Output value of our hash function. Intentionally opaque for safety and modularity.
#[derive(Clone, Copy, Eq, Hash, PartialEq, PartialOrd, Ord)]
pub struct HashValueV5 {
    hash: [u8; HashValueV5::LENGTH],
}

impl HashValueV5 {
    /// The length of the hash in bytes.
    pub const LENGTH: usize = 32;
    /// The length of the hash in bits.
    pub const LENGTH_IN_BITS: usize = Self::LENGTH * 8;

    /// Create a new [`HashValue`] from a byte array.
    pub fn new(hash: [u8; HashValueV5::LENGTH]) -> Self {
        HashValueV5 { hash }
    }

    /// Create from a slice (e.g. retrieved from storage).
    pub fn from_slice<T: AsRef<[u8]>>(bytes: T) -> Result<Self, HashValueParseError> {
        <[u8; Self::LENGTH]>::try_from(bytes.as_ref())
            .map_err(|_| HashValueParseError)
            .map(Self::new)
    }

    /// Dumps into a vector.
    pub fn to_vec(self) -> Vec<u8> {
        self.hash.to_vec()
    }

    /// Creates a zero-initialized instance.
    pub const fn zero() -> Self {
        HashValueV5 {
            hash: [0; HashValueV5::LENGTH],
        }
    }

    /// Create a cryptographically random instance.
    pub fn random() -> Self {
        let mut rng = OsRng;
        let hash: [u8; HashValueV5::LENGTH] = rng.gen();
        HashValueV5 { hash }
    }

    /// Creates a random instance with given rng. Useful in unit tests.
    pub fn random_with_rng<R: Rng>(rng: &mut R) -> Self {
        let hash: [u8; HashValueV5::LENGTH] = rng.gen();
        HashValueV5 { hash }
    }

    /// Convenience function that computes a `HashValue` internally equal to
    /// the sha3_256 of a byte buffer. It will handle hasher creation, data
    /// feeding and finalization.
    ///
    /// Note this will not result in the `<T as CryptoHash>::hash()` for any
    /// reasonable struct T, as this computes a sha3 without any ornaments.
    pub fn sha3_256_of(buffer: &[u8]) -> Self {
        let mut sha3 = Sha3::v256();
        sha3.update(buffer);
        HashValueV5::from_keccak(sha3)
    }

    #[cfg(test)]
    pub fn from_iter_sha3<'a, I>(buffers: I) -> Self
    where
        I: IntoIterator<Item = &'a [u8]>,
    {
        let mut sha3 = Sha3::v256();
        for buffer in buffers {
            sha3.update(buffer);
        }
        HashValueV5::from_keccak(sha3)
    }

    fn as_ref_mut(&mut self) -> &mut [u8] {
        &mut self.hash[..]
    }

    fn from_keccak(state: Sha3) -> Self {
        let mut hash = Self::zero();
        state.finalize(hash.as_ref_mut());
        hash
    }

    /// Returns the `index`-th bit in the bytes.
    pub fn bit(&self, index: usize) -> bool {
        assert!(index < Self::LENGTH_IN_BITS); // assumed precondition
        let pos = index / 8;
        let bit = 7 - index % 8;
        (self.hash[pos] >> bit) & 1 != 0
    }

    /// Returns the `index`-th nibble in the bytes.
    pub fn nibble(&self, index: usize) -> u8 {
        assert!(index < Self::LENGTH * 2); // assumed precondition
        let pos = index / 2;
        let shift = if index % 2 == 0 { 4 } else { 0 };
        (self.hash[pos] >> shift) & 0x0f
    }

    /// Returns a `HashValueBitIterator` over all the bits that represent this `HashValue`.
    pub fn iter_bits(&self) -> HashValueBitIterator<'_> {
        HashValueBitIterator::new(self)
    }

    /// Constructs a `HashValue` from an iterator of bits.
    pub fn from_bit_iter(
        iter: impl ExactSizeIterator<Item = bool>,
    ) -> Result<Self, HashValueParseError> {
        if iter.len() != Self::LENGTH_IN_BITS {
            return Err(HashValueParseError);
        }

        let mut buf = [0; Self::LENGTH];
        for (i, bit) in iter.enumerate() {
            if bit {
                buf[i / 8] |= 1 << (7 - i % 8);
            }
        }
        Ok(Self::new(buf))
    }

    /// Returns the length of common prefix of `self` and `other` in bits.
    pub fn common_prefix_bits_len(&self, other: HashValueV5) -> usize {
        self.iter_bits()
            .zip(other.iter_bits())
            .take_while(|(x, y)| x == y)
            .count()
    }

    /// Full hex representation of a given hash value.
    pub fn to_hex(self) -> String {
        format!("{:x}", &self)
    }

    /// Full hex representation of a given hash value with `0x` prefix.
    pub fn to_hex_literal(self) -> String {
        format!("{:#x}", &self)
    }

    /// Parse a given hex string to a hash value.
    pub fn from_hex<T: AsRef<[u8]>>(hex: T) -> Result<Self, HashValueParseError> {
        <[u8; Self::LENGTH]>::from_hex(hex)
            .map_err(|_| HashValueParseError)
            .map(Self::new)
    }

    /// Create a hash value whose contents are just the given integer. Useful for
    /// generating basic mock hash values.
    ///
    /// Ex: HashValue::from_u64(0x1234) => HashValue([0, .., 0, 0x12, 0x34])
    #[cfg(test)]
    pub fn from_u64(v: u64) -> Self {
        let mut hash = [0u8; Self::LENGTH];
        let bytes = v.to_be_bytes();
        hash[Self::LENGTH - bytes.len()..].copy_from_slice(&bytes[..]);
        Self::new(hash)
    }
}

impl ser::Serialize for HashValueV5 {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        if serializer.is_human_readable() {
            serializer.serialize_str(&self.to_hex())
        } else {
            // In order to preserve the Serde data model and help analysis tools,
            // make sure to wrap our value in a container with the same name
            // as the original type.
            serializer
                .serialize_newtype_struct("HashValue", serde_bytes::Bytes::new(&self.hash[..]))
        }
    }
}

impl<'de> de::Deserialize<'de> for HashValueV5 {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        if deserializer.is_human_readable() {
            let encoded_hash = <String>::deserialize(deserializer)?;
            HashValueV5::from_hex(encoded_hash.as_str())
                .map_err(<D::Error as ::serde::de::Error>::custom)
        } else {
            // See comment in serialize.
            #[derive(::serde::Deserialize)]
            #[serde(rename = "HashValue")]
            struct Value<'a>(&'a [u8]);

            let value = Value::deserialize(deserializer)?;
            Self::from_slice(value.0).map_err(<D::Error as ::serde::de::Error>::custom)
        }
    }
}

impl Default for HashValueV5 {
    fn default() -> Self {
        HashValueV5::zero()
    }
}

impl AsRef<[u8; HashValueV5::LENGTH]> for HashValueV5 {
    fn as_ref(&self) -> &[u8; HashValueV5::LENGTH] {
        &self.hash
    }
}

impl std::ops::Deref for HashValueV5 {
    type Target = [u8; Self::LENGTH];

    fn deref(&self) -> &Self::Target {
        &self.hash
    }
}

impl std::ops::Index<usize> for HashValueV5 {
    type Output = u8;

    fn index(&self, s: usize) -> &u8 {
        self.hash.index(s)
    }
}

impl fmt::Binary for HashValueV5 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for byte in &self.hash {
            write!(f, "{:08b}", byte)?;
        }
        Ok(())
    }
}

impl fmt::LowerHex for HashValueV5 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if f.alternate() {
            write!(f, "0x")?;
        }
        for byte in &self.hash {
            write!(f, "{:02x}", byte)?;
        }
        Ok(())
    }
}

impl fmt::Debug for HashValueV5 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "HashValue(")?;
        <Self as fmt::LowerHex>::fmt(self, f)?;
        write!(f, ")")?;
        Ok(())
    }
}

/// Will print shortened (4 bytes) hash
impl fmt::Display for HashValueV5 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        for byte in self.hash.iter().take(4) {
            write!(f, "{:02x}", byte)?;
        }
        Ok(())
    }
}

impl From<HashValueV5> for Bytes {
    fn from(value: HashValueV5) -> Bytes {
        Bytes::copy_from_slice(value.hash.as_ref())
    }
}

impl FromStr for HashValueV5 {
    type Err = HashValueParseError;

    fn from_str(s: &str) -> Result<Self, HashValueParseError> {
        HashValueV5::from_hex(s)
    }
}

/// Parse error when attempting to construct a HashValue
#[derive(Clone, Copy, Debug)]
pub struct HashValueParseError;

impl fmt::Display for HashValueParseError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "unable to parse HashValue")
    }
}

impl std::error::Error for HashValueParseError {}

/// An iterator over `HashValue` that generates one bit for each iteration.
pub struct HashValueBitIterator<'a> {
    /// The reference to the bytes that represent the `HashValue`.
    hash_bytes: &'a [u8],
    pos: std::ops::Range<usize>,
    // invariant hash_bytes.len() == HashValue::LENGTH;
    // invariant pos.end == hash_bytes.len() * 8;
}

impl<'a> HashValueBitIterator<'a> {
    /// Constructs a new `HashValueBitIterator` using given `HashValue`.
    fn new(hash_value: &'a HashValueV5) -> Self {
        HashValueBitIterator {
            hash_bytes: hash_value.as_ref(),
            pos: (0..HashValueV5::LENGTH_IN_BITS),
        }
    }

    /// Returns the `index`-th bit in the bytes.
    fn get_bit(&self, index: usize) -> bool {
        assert!(index < self.pos.end); // assumed precondition
        assert!(self.hash_bytes.len() == HashValueV5::LENGTH); // invariant
        assert!(self.pos.end == self.hash_bytes.len() * 8); // invariant
        let pos = index / 8;
        let bit = 7 - index % 8;
        (self.hash_bytes[pos] >> bit) & 1 != 0
    }
}

impl std::iter::Iterator for HashValueBitIterator<'_> {
    type Item = bool;

    fn next(&mut self) -> Option<Self::Item> {
        self.pos.next().map(|x| self.get_bit(x))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.pos.size_hint()
    }
}

impl std::iter::DoubleEndedIterator for HashValueBitIterator<'_> {
    fn next_back(&mut self) -> Option<Self::Item> {
        self.pos.next_back().map(|x| self.get_bit(x))
    }
}

impl std::iter::ExactSizeIterator for HashValueBitIterator<'_> {}
