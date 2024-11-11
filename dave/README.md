# Dave

The implementation of the Dave fraud-proof algorithm.

## The Dave fraud-proof algorithm — triumphing over Sybils with a laptop and a small collateral

The Dave fraud-proof algorithm offers an unprecedented combination of decentralization, security, and liveness.
The resources that must be mobilized by an honest participant to defeat an adversary grow only logarithmically with what the adversary ultimately loses.
As a consequence, there is no need to introduce high bonds that prevent an adversary from creating too many Sybils.
This makes the system very inclusive and frees participants from having to pool resources among themselves to engage the protocol.
Finally, the maximum delay to finalization also grows only logarithmically with total adversarial expenditure, with the smallest multiplicative factor to date.
In summary: the entire dispute completes in 2–5 challenge periods, the only way to break consensus is to censor the honest party for more than one challenge period, and the costs of engaging in the dispute are minimal.

We've published our initial research [here](https://arxiv.org/abs/2411.05463), and committed it [here](docs/dave.pdf) for convenience.
