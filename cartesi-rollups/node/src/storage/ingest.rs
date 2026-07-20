// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The blockchain reader's writer role: consensus data. One public
//! operation - the tick's atomic append of watermark, inputs, and
//! epochs. The Rust-side sequencing checks produce the typed errors;
//! the schema triggers back them against raw writers.

use super::error::{Result, StorageError};
use super::{Epoch, Input, InputId, Storage};
use crate::storage::convert::u64_to_i64;

use alloy::hex::ToHexExt;
use rusqlite::{Transaction, params};

impl Storage {
    /// Records one blockchain-reader tick: raises the processed-block
    /// watermark and appends the tick's inputs and sealed epochs, all
    /// in one transaction. Inputs must advance per
    /// [`InputId::validate_next`]; epochs must arrive densely.
    pub fn insert_consensus_data<'a>(
        &mut self,
        last_processed_block: u64,
        inputs: impl Iterator<Item = &'a Input>,
        epochs: impl Iterator<Item = &'a Epoch>,
    ) -> Result<()> {
        self.write(|tx| {
            raise_watermark_in(tx, last_processed_block)?;
            insert_inputs_in(tx, inputs)?;
            insert_epochs_in(tx, epochs)?;
            Ok(())
        })
    }
}

/// Monotonic watermark raise: equal or lower submissions absorb
/// silently, so a replayed tick is a no-op rather than an error.
pub(super) fn raise_watermark_in(tx: &Transaction, block: u64) -> Result<()> {
    tx.execute(
        r#"
        INSERT INTO latest_processed (id, block) VALUES (1, ?1)
        ON CONFLICT (id) DO UPDATE SET block = MAX(block, excluded.block)
        "#,
        params![u64_to_i64(block)],
    )
    .map_err(anyhow::Error::from)?;
    Ok(())
}

fn validate_insert(current: &Option<InputId>, next: &InputId) -> bool {
    match &current {
        Some(i) if !i.validate_next(next) => false,
        None if next.input_index_in_epoch != 0 => false,
        _ => true,
    }
}

pub(super) fn insert_inputs_in<'a>(
    tx: &Transaction,
    inputs: impl Iterator<Item = &'a Input>,
) -> Result<()> {
    let mut inputs = inputs.peekable();
    if inputs.peek().is_none() {
        return Ok(());
    }

    let mut current_input = super::queries::last_input_in(tx)?;

    let mut stmt = tx
        .prepare_cached(
            r#"
            INSERT INTO inputs (epoch_number, input_index_in_epoch, input)
            VALUES (?1, ?2, ?3)
            "#,
        )
        .map_err(anyhow::Error::from)?;

    for input in inputs {
        if !validate_insert(&current_input, &input.id) {
            return Err(StorageError::InconsistentInput {
                previous: current_input,
                provided: input.id.clone(),
            });
        }

        stmt.execute(params![
            u64_to_i64(input.id.epoch_number),
            u64_to_i64(input.id.input_index_in_epoch),
            input.data
        ])
        .map_err(anyhow::Error::from)?;

        current_input = Some(input.id.clone());
    }

    Ok(())
}

pub(super) fn insert_epochs_in<'a>(
    tx: &Transaction,
    epochs: impl Iterator<Item = &'a Epoch>,
) -> Result<()> {
    let mut epochs = epochs.peekable();
    if epochs.peek().is_none() {
        return Ok(());
    }

    let mut stmt = tx
        .prepare_cached(
            r#"
            INSERT INTO epochs
            (epoch_number, input_index_boundary, root_tournament, block_created_number)
            VALUES (?1, ?2, ?3, ?4)
            "#,
        )
        .map_err(anyhow::Error::from)?;

    for (next_epoch, epoch) in (super::queries::epoch_count_in(tx)?..).zip(epochs) {
        if epoch.epoch_number != next_epoch {
            return Err(StorageError::InconsistentEpoch {
                expected: next_epoch,
                provided: epoch.epoch_number,
            });
        }

        stmt.execute(params![
            u64_to_i64(epoch.epoch_number),
            u64_to_i64(epoch.input_index_boundary),
            epoch.root_tournament.encode_hex(),
            u64_to_i64(epoch.block_created_number)
        ])
        .map_err(anyhow::Error::from)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::sql::test_helper;
    use super::*;
    use alloy::hex::FromHex;
    use alloy::primitives::Address;

    fn storage() -> (tempfile::TempDir, Storage) {
        test_helper::setup_storage()
    }

    #[test]
    fn watermark_rises_and_absorbs_replays() {
        let (_handle, mut s) = storage();

        assert_eq!(s.latest_processed_block().unwrap(), 0);
        s.write(|tx| raise_watermark_in(tx, 10)).unwrap();
        assert_eq!(s.latest_processed_block().unwrap(), 10);

        // a replayed or stale tick absorbs instead of erroring
        s.write(|tx| raise_watermark_in(tx, 10)).unwrap();
        s.write(|tx| raise_watermark_in(tx, 3)).unwrap();
        assert_eq!(s.latest_processed_block().unwrap(), 10);

        s.write(|tx| raise_watermark_in(tx, 200)).unwrap();
        assert_eq!(s.latest_processed_block().unwrap(), 200);
    }

    #[test]
    fn inputs_must_be_sequential_and_batches_are_atomic() {
        let (_handle, mut s) = storage();
        let data = vec![1u8];

        let input = |epoch, index| Input {
            id: InputId {
                epoch_number: epoch,
                input_index_in_epoch: index,
            },
            data: data.clone(),
        };

        // first input of the database must have index 0
        assert!(
            s.insert_consensus_data(1, [&input(0, 1)].into_iter(), [].into_iter())
                .is_err()
        );

        s.insert_consensus_data(2, [&input(0, 0), &input(0, 1)].into_iter(), [].into_iter())
            .unwrap();

        // a failing batch rolls back whole: the valid prefix does not land
        assert!(
            s.insert_consensus_data(3, [&input(0, 2), &input(0, 4)].into_iter(), [].into_iter())
                .is_err()
        );
        assert_eq!(
            s.last_input().unwrap().unwrap().input_index_in_epoch,
            1,
            "the failed batch must not leave a partial prefix"
        );
        assert_eq!(
            s.latest_processed_block().unwrap(),
            2,
            "the failed batch must not raise the watermark"
        );

        // an epoch skip re-enters at index 0
        s.insert_consensus_data(4, [&input(0, 2), &input(2, 0)].into_iter(), [].into_iter())
            .unwrap();
        assert!(
            s.input(&InputId {
                epoch_number: 2,
                input_index_in_epoch: 0
            })
            .unwrap()
            .is_some()
        );
    }

    #[test]
    fn epochs_must_be_dense() {
        let (_handle, mut s) = storage();

        let epoch = |number| Epoch {
            epoch_number: number,
            input_index_boundary: 0,
            root_tournament: Address::ZERO,
            block_created_number: number * 2,
        };

        assert!(matches!(
            s.insert_consensus_data(1, [].into_iter(), [&epoch(1)].into_iter()),
            Err(StorageError::InconsistentEpoch {
                expected: 0,
                provided: 1
            })
        ));
        assert_eq!(s.epoch_count().unwrap(), 0);

        s.insert_consensus_data(2, [].into_iter(), [&epoch(0), &epoch(1)].into_iter())
            .unwrap();
        assert_eq!(s.epoch_count().unwrap(), 2);

        // a gapped batch rolls back whole
        assert!(
            s.insert_consensus_data(3, [].into_iter(), [&epoch(2), &epoch(4)].into_iter())
                .is_err()
        );
        assert_eq!(s.epoch_count().unwrap(), 2);

        let tournament = Address::from_hex("0x8dA443F84fEA710266C8eB6bC34B71702d033EF2").unwrap();
        s.insert_consensus_data(
            4,
            [].into_iter(),
            [&Epoch {
                epoch_number: 2,
                input_index_boundary: 99,
                root_tournament: tournament,
                block_created_number: 260,
            }]
            .into_iter(),
        )
        .unwrap();
        let stored = s.last_sealed_epoch().unwrap().unwrap();
        assert_eq!(stored.epoch_number, 2);
        assert_eq!(stored.input_index_boundary, 99);
        assert_eq!(stored.root_tournament, tournament);
    }
}
