# Dave

Dave is a permissionless, interactive fraud-proof system. This repo contains the Dave software suite, including support for both rollups and compute (_i.e._ a one-shot computation, like a rollup without inputs):

* Solidity smart contracts;
* off-chain testing node in Lua;
* off-chain reference node in Rust;
* dispute algorithm specification.

---

## What's in a name

Our fraud-proof system is called _Dave_.
Just Dave.
It's neither an acronym nor an abbreviation, but a name.
Like most names, it should be written in lower case with an initial capital, that is, "Dave".

Dave is permissionless.
This means anyone can participate in the consensus.
Since anyone can participate, there's the possibility of Sybil attacks, where an attacker can generate an army of fake personas and try to shift the consensus in their favour.

Dave's security is one of N: a single honest validator can enforce the correct result.
It doesn't matter if it's you against the world.
If you're honest, Dave's got your back; you can fight a mountain of powerful, well-funded crooks and win, using a single laptop, in a relatively timely manner.

Dave is inspired by the David vs. Goliath archetype.


---

## Execution Environment

Dave uses the [Cartesi Machine](https://github.com/cartesi/machine-emulator) as its execution environment.
The Cartesi Machine is a RISC-V emulator.
Its onchain implementation can be found [here](https://github.com/cartesi/machine-solidity-step).
The Cartesi Machine state-transition function is implemented in two layers: the big-machine and the micro-architecture.
The former implements the RV64GC ISA, while the latter implements the much smaller RV64I ISA.
Using a technique called _machine swapping_ and leveraging good compilers, we implement in Solidity only the micro-architecture's state-transition function, while the execution environment can support a much larger set of extensions.

Nevertheless, Dave was designed to be agnostic on its execution environment.
As long as one can provide a self-contained state-transition function, Dave will work.


---

## Algorithms

### Permissionless Refereed Tournaments

The first implementation of Dave is based on the Permissionless Refereed Tournaments (PRT) primitive.
The paper can be found [here](https://arxiv.org/abs/2212.12439).
The maximum delay and expenses grow logarithmically on the number of Sybils, and hardware and bonds are both low and constant, regardless of the number of Sybils.
As such, the defenders have an exponential resource advantage over the attackers (making the algorithm secure), it's easy to become a validator (low bonds and hardware requirements, making the algorithm decentralized), and delay grows slowly.


### Dave fraud-proof algorithm

Although delay grows logarithmically in the Permissionless Refereed Tournaments (PRT) algorithm, the constant multiplying this logarithm is high, harming its liveness.

The second implementation of Dave will be based on the eponymous Dave algorithm, which improves the liveness of PRT, while maintaining its attractive security and decentralization properties.
We've published our initial research [here](https://arxiv.org/abs/2411.05463), and presented our findings at Devcon 24 [here](https://youtu.be/dI_3neyXVl0).


---

## Running Dave

This repository offers two development setups for Dave: one running inside a Docker container and one running natively (outside Docker).
Choose the setup that best fits your workflow.

### Docker Environment

**Dependencies:**

- git
- Docker
- pnpm
- just
- GNU make
- [foundry](https://github.com/foundry-rs/foundry)

**Setup Steps:**

1. **Clone the Repository:**
   Ensure you have cloned the repository to your local machine.

2. **Initialize the Docker Environment:**
   Run the following command to set up the Docker environment (it will take a while):
   ```bash
   just setup-docker
   ```

3. **Execute Commands Inside Docker:**
   To run any command within the Docker container, prefix your command as follows:
   ```bash
   just run-dockered <command>
   ```

### Local Environment

If you prefer running Dave natively on your machine, you'll need additional dependencies.

**Additional Dependencies:**

- A C++ compiler
- A local installation of the Cartesi machine
- Lua 5.4
- Rust
- [`xgenext2fs`](https://github.com/cartesi/genext2fs)

**Setup Steps:**

1. **Clone the Repository:**
   Make sure the repository is cloned locally.

2. **Initialize the Local Environment:**
   Run the following command to set up the environment (it will take a while):
   ```bash
   just setup-local
   ```

### Running Examples

The repository includes examples for different components of Dave:

- **PRT Lua Client (Compute):**
  Follow the instructions in the [PRT Lua client README](prt/tests/compute/README.md).

- **PRT Rust Node (Rollups):**
  Follow the instructions in the [PRT Rust node README](prt/tests/rollups/README.md).


---

## Contributing

Thank you for your interest in Cartesi!
Head over to our [Contributing Guidelines](CONTRIBUTING.md) for instructions on how to sign our Contributors Agreement and get started with Cartesi!

Please note we have a [Code of Conduct](CODE_OF_CONDUCT.md), please follow it in all your interactions with the project.

---

## License

The repository and all contributions are licensed under [APACHE 2.0](https://www.apache.org/licenses/LICENSE-2.0).
Please review our [LICENSE](LICENSE) file.

---

<div align="center">
  <a href="https://cartesi.io"><img alt="Dave" src=".github/assets/dave-img.jpeg" width=600></a>
  <br />
  <h3><a href="https://github.com/cartesi/dave">Dave</a>.</h3>
</div>
