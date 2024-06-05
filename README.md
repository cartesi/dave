# Dave

Dave is a permissionless, interactive fraud-proof system. This repo contains the Dave software suite, including support for both rollups and compute (_i.e._ a one-shot computation, like a rollup without inputs):

* Solidity smart contracts;
* off-chain testing node in Lua;
* off-chain reference node in Rust;
* dispute algorithm specification.


## Running Dave

This project uses git submodules.
Remember to either clone the repository with the flag `--recurse-submodules`, or run `git submodule update --recursive --init` after cloning.

To run the Lua node, follow the instructions [here](permissionless-arbitration/lua_node/README.md).


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


## Execution Environment

Dave uses the [Cartesi Machine](https://github.com/cartesi/machine-emulator) as its execution environment.
The Cartesi Machine is a RISC-V emulator.
Its onchain implementation can be found [here](https://github.com/cartesi/machine-solidity-step).
The Cartesi Machine state-transition function is implemented in two layers: the big-machine and the micro-architecture.
The former implements the RV64GC ISA, while the latter implements the much smaller RV64I ISA.
Using a technique called _machine swapping_ and leveraging good compilers, we implement in Solidity only the micro-architecture's state-transition function, while the execution environment can support a much larger set of extensions.

Nevertheless, Dave was designed to be agnostic on its execution environment.
As long as one can provide a self-contained state-transition function, Dave will work.


## Algorithm

Dave is based on the Permissionless Refereed Tournaments primitive.
The paper can be found [here](https://arxiv.org/abs/2212.12439).
The maximum delay grows logarithmically on the number of Sybils, whereas the computation resources and stakes are constant, and don't grow on the number of Sybils.


## Status

The project is still in its prototyping stages.



## Contributing

Thank you for your interest in Cartesi!
Head over to our [Contributing Guidelines](CONTRIBUTING.md) for instructions on how to sign our Contributors Agreement and get started with Cartesi!

Please note we have a [Code of Conduct](CODE_OF_CONDUCT.md), please follow it in all your interactions with the project.

## License

The repository and all contributions are licensed under [APACHE 2.0](https://www.apache.org/licenses/LICENSE-2.0).
Please review our [LICENSE](LICENSE) file.

---

<div align="center">
  <a href="https://cartesi.io"><img alt="Dave" src="doc/assets/dave-img.jpeg" width=600></a>
  <br />
  <h3><a href="https://github.com/cartesi/dave">Dave</a>.</h3>
</div>
