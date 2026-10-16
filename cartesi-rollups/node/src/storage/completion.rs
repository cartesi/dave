// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

//! The epoch manager's durable completion cursor. Snapshot and dispute-row
//! collection stays on the machine runner, after it observes this cursor.

use super::Storage;
use super::convert::u64_to_i64;
use super::error::{Result, StorageError};
use super::queries::{epoch_count_in, unfinished_epoch_number_in};
use rusqlite::Transaction;

impl Storage {
    /// Releases an epoch after finalized settlement and bond recovery. The
    /// caller must stop using its Hero before making the epoch collectible.
    /// Epochs complete in order, and only ingested ones. The cursor starts
    /// at the directory's seed epoch, which may be ahead of ingestion until
    /// that epoch's seal arrives (the manager waits for it); once the seed
    /// epoch completes, it points at most just past the ingested prefix.
    pub fn complete_epoch(&mut self, epoch_number: u64) -> Result<()> {
        self.write(|tx| {
            let expected = unfinished_epoch_number_in(tx)?;
            if epoch_number != expected {
                return Err(StorageError::InconsistentEpoch {
                    expected,
                    provided: epoch_number,
                });
            }
            if epoch_number >= epoch_count_in(tx)? {
                return Err(StorageError::DataNotFound {
                    description: format!("epoch {epoch_number}, which ingestion has not seen"),
                });
            }
            tx.execute(
                "UPDATE epoch_completion SET next_epoch = next_epoch + 1
                 WHERE id = 1 AND next_epoch = ?1",
                [u64_to_i64(epoch_number)],
            )?;
            Ok(())
        })
    }
}

/// Starts a new directory's cursor at its seed epoch: the directory owns
/// that epoch and later ones and never touches an earlier one, whose bonds
/// are the operator's (node README). A genesis seed leaves it at 0.
pub(super) fn seed_cursor_in(tx: &Transaction, seed_epoch: u64) -> Result<()> {
    tx.execute(
        "UPDATE epoch_completion SET next_epoch = ?1
         WHERE id = 1 AND next_epoch = 0",
        [u64_to_i64(seed_epoch)],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::Epoch;
    use crate::storage::queries::setup_settlement_storage;
    use crate::storage::sql::test_helper::stub_snapshot;
    use alloy::primitives::Address;

    fn epochs(count: u64) -> Vec<Epoch> {
        (0..count)
            .map(|epoch_number| Epoch {
                epoch_number,
                input_index_boundary: 0,
                root_tournament: Address::repeat_byte(epoch_number as u8 + 1),
                block_created_number: epoch_number + 1,
            })
            .collect()
    }

    #[test]
    fn unfinished_epoch_survives_restart_and_does_not_follow_latest() {
        let (dir, mut storage) = setup_settlement_storage();
        assert!(storage.unfinished_epoch().unwrap().is_none());
        assert!(storage.complete_epoch(0).is_err());

        let epochs = epochs(3);
        storage
            .insert_consensus_data(3, [].iter(), epochs.iter())
            .unwrap();
        assert_eq!(storage.unfinished_epoch().unwrap().unwrap().epoch_number, 0);
        storage.complete_epoch(0).unwrap();
        drop(storage);

        let mut restarted = Storage::new(dir.path()).unwrap();
        assert_eq!(
            restarted.unfinished_epoch().unwrap().unwrap().epoch_number,
            1
        );
        assert!(restarted.complete_epoch(0).is_err());
        assert!(restarted.complete_epoch(2).is_err());
        assert_eq!(
            restarted.unfinished_epoch().unwrap().unwrap().epoch_number,
            1
        );
        restarted.complete_epoch(1).unwrap();
        restarted.complete_epoch(2).unwrap();
        assert!(restarted.unfinished_epoch().unwrap().is_none());
        assert!(restarted.complete_epoch(3).is_err());
    }

    #[test]
    fn idle_runner_prunes_only_completed_epochs_and_keeps_its_newest_boundary() {
        let (_dir, mut storage) = setup_settlement_storage();
        let epochs = epochs(6);
        storage
            .insert_consensus_data(3, [].iter(), epochs.iter().take(3))
            .unwrap();

        let hash = |epoch: u64| [epoch as u8 + 1; 32];
        let boundaries: Vec<_> = (0..=4)
            .map(|epoch| stub_snapshot(&storage, &hash(epoch)))
            .collect();
        for epoch in 0..=3 {
            storage.insert_boundary(epoch, 0, &hash(epoch)).unwrap();
            storage
                .connection
                .execute(
                    "INSERT INTO sling_nodes VALUES (?1, 0, 0, x'00', x'01')",
                    [u64_to_i64(epoch)],
                )
                .unwrap();
        }

        // Both ingestion and execution are ahead of the manager. An idle
        // runner may not discard its epoch zero.
        let plan = storage.advance_plan().unwrap();
        assert!(plan.inputs.is_empty());
        assert!(!plan.sealed);
        for epoch in 0..=3 {
            assert!(storage.snapshot_dir(epoch, 0).unwrap().is_some());
        }

        storage.complete_epoch(0).unwrap();
        storage.complete_epoch(1).unwrap();
        // Cursor publication itself does not delete the runner's files.
        assert!(storage.snapshot_dir(0, 0).unwrap().is_some());
        storage.advance_plan().unwrap();
        for epoch in 0..=3 {
            let retained = epoch >= 2;
            assert_eq!(storage.snapshot_dir(epoch, 0).unwrap().is_some(), retained);
            assert_eq!(boundaries[epoch as usize].is_dir(), retained);
            let nodes: i64 = storage
                .connection
                .query_row(
                    "SELECT COUNT(*) FROM sling_nodes WHERE epoch = ?1",
                    [u64_to_i64(epoch)],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(nodes, i64::from(retained));
        }

        storage
            .insert_consensus_data(6, [].iter(), epochs.iter().skip(3))
            .unwrap();
        for epoch in 2..=4 {
            storage.complete_epoch(epoch).unwrap();
        }
        storage.advance_plan().unwrap();
        assert!(storage.snapshot_dir(2, 0).unwrap().is_none());
        assert!(storage.snapshot_dir(3, 0).unwrap().is_some());
        assert_eq!(storage.next_input_id().unwrap().epoch_number, 3);

        // Once the runner publishes another boundary, the previously newest
        // completed epoch becomes collectible without another completion.
        storage.insert_boundary(4, 0, &hash(4)).unwrap();
        storage.advance_plan().unwrap();
        assert!(storage.snapshot_dir(3, 0).unwrap().is_none());
        assert_eq!(storage.next_input_id().unwrap().epoch_number, 4);
        assert!(boundaries[4].is_dir());
    }
}
