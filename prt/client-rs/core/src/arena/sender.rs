//! This module defines the struct [EthArenaSender] that is responsible for the sending transactions
//! to tournaments

use async_trait::async_trait;
use log::trace;
use std::{str::FromStr, sync::Arc};

use alloy::{
    contract::Error as ContractError,
    network::{Ethereum, EthereumWallet, NetworkWallet},
    providers::{
        fillers::{
            BlobGasFiller, ChainIdFiller, FillProvider, GasFiller, JoinFill, NonceFiller,
            WalletFiller,
        },
        Identity, Provider, ProviderBuilder, RootProvider,
    },
    signers::local::PrivateKeySigner,
    sol_types::private::{Address, Bytes, B256},
    transports::{
        http::{Client, Http},
        RpcError, TransportErrorKind,
    },
};

use crate::{
    arena::{arena::MatchID, config::BlockchainConfig},
    machine::MachineProof,
};
use cartesi_dave_kms::{CommonSignature, KmsSignerBuilder};
use cartesi_dave_merkle::{Digest, MerkleProof};
use cartesi_prt_contracts::{leaftournament, nonleaftournament, tournament};

pub type SenderFiller = FillProvider<
    JoinFill<
        JoinFill<
            Identity,
            JoinFill<GasFiller, JoinFill<BlobGasFiller, JoinFill<NonceFiller, ChainIdFiller>>>,
        >,
        WalletFiller<EthereumWallet>,
    >,
    RootProvider<Http<Client>>,
    Http<Client>,
    Ethereum,
>;
type Result<T> = std::result::Result<T, ContractError>;

#[derive(Clone)]
pub struct EthArenaSender {
    client: Arc<SenderFiller>,
    wallet_address: Address,
}

impl EthArenaSender {
    pub async fn new(config: &BlockchainConfig) -> anyhow::Result<Self> {
        let signer: Box<CommonSignature>;

        let has_awsconfig = config.aws_config.aws_kms_key_id.is_some();

        if has_awsconfig {
            let key_id = config.aws_config.aws_kms_key_id.clone().unwrap();
            let kms_signer = KmsSignerBuilder::new()
                .await
                .with_chain_id(config.web3_chain_id)
                .with_key_id(key_id)
                .build()
                .await?;
            signer = Box::new(kms_signer);
        } else {
            let local_signer = PrivateKeySigner::from_str(config.web3_private_key.as_str())?;
            signer = Box::new(local_signer);
        }

        let wallet = EthereumWallet::from(signer);
        let wallet_address =
            <EthereumWallet as NetworkWallet<Ethereum>>::default_signer_address(&wallet);

        let url = config.web3_rpc_url.parse()?;
        let provider = ProviderBuilder::new()
            .with_recommended_fillers()
            .wallet(wallet)
            .with_chain(
                config
                    .web3_chain_id
                    .try_into()
                    .expect("fail to convert chain id"),
            )
            .on_http(url);
        let client = Arc::new(provider);

        Ok(Self {
            client,
            wallet_address,
        })
    }

    pub fn client(&self) -> Arc<SenderFiller> {
        self.client.clone()
    }

    pub async fn nonce(&self) -> std::result::Result<u64, RpcError<TransportErrorKind>> {
        Ok(self
            .client
            .get_transaction_count(self.wallet_address)
            .await?)
    }
}

/// The [ArenaSender] trait defines the interface for the creation and management of tournaments.
#[async_trait]
pub trait ArenaSender: Send + Sync {
    async fn join_tournament(
        &self,
        tournament: Address,
        proof: &MerkleProof,
        left_child: Digest,
        right_child: Digest,
    ) -> Result<()>;

    async fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) -> Result<()>;

    async fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> Result<()>;

    async fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<()>;

    async fn win_timeout_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<()>;

    async fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> Result<()>;

    async fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) -> Result<()>;

    async fn eliminate_match(&self, tournament: Address, match_id: MatchID) -> Result<()>;
}

#[async_trait]
impl ArenaSender for EthArenaSender {
    async fn join_tournament(
        &self,
        tournament: Address,
        proof: &MerkleProof,
        left_child: Digest,
        right_child: Digest,
    ) -> Result<()> {
        let tournament = tournament::Tournament::new(tournament, &self.client);
        let siblings = proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        trace!(
            "final state for tournament {} at position {}",
            proof.node,
            proof.position
        );
        tournament
            .joinTournament(
                proof.node.into(),
                siblings,
                left_child.into(),
                right_child.into(),
            )
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }

    async fn advance_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        new_left_node: Digest,
        new_right_node: Digest,
    ) -> Result<()> {
        let tournament = tournament::Tournament::new(tournament, &self.client);
        tournament
            .advanceMatch(
                match_id.into(),
                left_node.into(),
                right_node.into(),
                new_left_node.into(),
                new_right_node.into(),
            )
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }

    async fn seal_inner_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> Result<()> {
        let tournament = nonleaftournament::NonLeafTournament::new(tournament, &self.client);
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        tournament
            .sealInnerMatchAndCreateInnerTournament(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
            )
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }

    async fn win_inner_match(
        &self,
        tournament: Address,
        child_tournament: Address,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<()> {
        let tournament = nonleaftournament::NonLeafTournament::new(tournament, &self.client);
        tournament
            .winInnerMatch(child_tournament, left_node.into(), right_node.into())
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }

    async fn win_timeout_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
    ) -> Result<()> {
        let tournament = nonleaftournament::NonLeafTournament::new(tournament, &self.client);
        tournament
            .winMatchByTimeout(match_id.into(), left_node.into(), right_node.into())
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }

    async fn seal_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_leaf: Digest,
        right_leaf: Digest,
        initial_hash_proof: &MerkleProof,
    ) -> Result<()> {
        let tournament = leaftournament::LeafTournament::new(tournament, &self.client);
        let initial_hash_siblings = initial_hash_proof
            .siblings
            .iter()
            .map(|h| -> B256 { (*h).into() })
            .collect();
        tournament
            .sealLeafMatch(
                match_id.into(),
                left_leaf.into(),
                right_leaf.into(),
                initial_hash_proof.node.into(),
                initial_hash_siblings,
            )
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }

    async fn win_leaf_match(
        &self,
        tournament: Address,
        match_id: MatchID,
        left_node: Digest,
        right_node: Digest,
        proofs: MachineProof,
    ) -> Result<()> {
        let tournament = leaftournament::LeafTournament::new(tournament, &self.client);
        tournament
            .winLeafMatch(
                match_id.into(),
                left_node.into(),
                right_node.into(),
                Bytes::from(proofs),
            )
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }

    async fn eliminate_match(&self, tournament: Address, match_id: MatchID) -> Result<()> {
        let tournament = tournament::Tournament::new(tournament, &self.client);
        tournament
            .eliminateMatchByTimeout(match_id.into())
            .send()
            .await?
            .watch()
            .await?;
        Ok(())
    }
}
