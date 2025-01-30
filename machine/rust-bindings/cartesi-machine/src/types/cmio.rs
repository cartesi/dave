// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

use crate::{constants, types::Hash};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CmioRequest {
    Automatic(AutomaticReason),
    Manual(ManualReason),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AutomaticReason {
    Progress { mille_progress: u32 },
    TxOutput { data: Vec<u8> },
    TxReport { data: Vec<u8> },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ManualReason {
    RxAccepted { output_hashes_root_hash: Hash },
    RxRejected,
    TxException { message: String },
    GIO { domain: u16, data: Vec<u8> },
}

impl CmioRequest {
    pub fn new(cmd: u8, reason: u16, data: Vec<u8>) -> Self {
        use constants::cmio::{commands, tohost::automatic, tohost::manual};
        match cmd {
            commands::YIELD_AUTOMATIC => Self::Automatic(match reason {
                automatic::PROGRESS => AutomaticReason::Progress {
                    mille_progress: u32::from_le_bytes(
                        data.try_into().expect("malformed progress integer"),
                    ),
                },
                automatic::TX_OUTPUT => AutomaticReason::TxOutput { data },
                automatic::TX_REPORT => AutomaticReason::TxReport { data },
                _ => panic!("Unknown automatic yield reason {}", reason),
            }),

            commands::YIELD_MANUAL => Self::Manual(match reason {
                manual::RX_ACCEPTED => ManualReason::RxAccepted {
                    output_hashes_root_hash: data
                        .try_into()
                        .expect("malformed `output_hashes_root_hash`"),
                },
                manual::RX_REJECTED => ManualReason::RxRejected,
                manual::TX_EXCEPTION => ManualReason::TxException {
                    message: String::from_utf8_lossy(&data).into_owned(),
                },
                domain => ManualReason::GIO { domain, data },
            }),
            _ => panic!("Unknown cmio command {}", cmd),
        }
    }

    pub fn cmd_and_reason(&self) -> (u8, u16) {
        use constants::cmio::{commands, tohost::automatic, tohost::manual};
        match self {
            CmioRequest::Automatic(automatic_reason) => (
                commands::YIELD_AUTOMATIC,
                match automatic_reason {
                    AutomaticReason::Progress { .. } => automatic::PROGRESS,
                    AutomaticReason::TxOutput { .. } => automatic::TX_OUTPUT,
                    AutomaticReason::TxReport { .. } => automatic::TX_REPORT,
                },
            ),
            CmioRequest::Manual(manual_reason) => (
                commands::YIELD_MANUAL,
                match manual_reason {
                    ManualReason::RxAccepted { .. } => manual::RX_ACCEPTED,
                    ManualReason::RxRejected => manual::RX_REJECTED,
                    ManualReason::TxException { .. } => manual::TX_EXCEPTION,
                    ManualReason::GIO { domain, .. } => *domain,
                },
            ),
        }
    }

    pub fn cmd(&self) -> u8 {
        self.cmd_and_reason().0
    }

    pub fn reason(&self) -> u16 {
        self.cmd_and_reason().1
    }
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum CmioResponseReason {
    Advance = cartesi_machine_sys::CM_CMIO_YIELD_REASON_ADVANCE_STATE as isize,
    Inspect = cartesi_machine_sys::CM_CMIO_YIELD_REASON_INSPECT_STATE as isize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use constants::cmio;

    macro_rules! test_req {
        ($cmd:expr, $reason:expr, $data:expr, $expected:expr) => {{
            let r = CmioRequest::new($cmd, $reason, $data);
            assert_eq!(r, $expected);
            assert_eq!(r.cmd_and_reason(), ($cmd, $reason));
            assert_eq!(r.cmd(), $cmd);
            assert_eq!(r.reason(), $reason);
        }};
    }

    #[test]
    fn test_cmio_contructor() {
        test_req!(
            cmio::commands::YIELD_AUTOMATIC,
            cmio::tohost::automatic::TX_REPORT,
            vec![],
            CmioRequest::Automatic(AutomaticReason::TxReport { data: vec![] })
        );
        test_req!(
            cmio::commands::YIELD_AUTOMATIC,
            cmio::tohost::automatic::TX_OUTPUT,
            vec![],
            CmioRequest::Automatic(AutomaticReason::TxOutput { data: vec![] })
        );
        test_req!(
            cmio::commands::YIELD_AUTOMATIC,
            cmio::tohost::automatic::PROGRESS,
            42u32.to_ne_bytes().to_vec(),
            CmioRequest::Automatic(AutomaticReason::Progress { mille_progress: 42 })
        );

        test_req!(
            cmio::commands::YIELD_MANUAL,
            cmio::tohost::manual::RX_ACCEPTED,
            vec![0; 32],
            CmioRequest::Manual(ManualReason::RxAccepted {
                output_hashes_root_hash: Hash::default()
            })
        );
        test_req!(
            cmio::commands::YIELD_MANUAL,
            cmio::tohost::manual::RX_REJECTED,
            vec![],
            CmioRequest::Manual(ManualReason::RxRejected)
        );
        test_req!(
            cmio::commands::YIELD_MANUAL,
            cmio::tohost::manual::TX_EXCEPTION,
            vec![],
            CmioRequest::Manual(ManualReason::TxException {
                message: "".to_owned()
            })
        );
    }
}
