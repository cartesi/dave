// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.17;

import {Machine} from "src/types/Machine.sol";
import {Tree} from "src/types/Tree.sol";

/// @dev Test-only sparse commitment families for configurable tree heights.
/// The families differ at only one leaf, so every node and proof is derived in
/// linear space. This keeps tests independent from deployment geometry without
/// attempting to materialize 2^height leaves.
abstract contract ConfigurableCommitmentFixture {
    using Tree for Tree.Node;

    enum CommitmentShape {
        SAME,
        RIGHTMOST_DIFFERENT,
        SECOND_DIFFERENT,
        FIRST_DIFFERENT,
        THIRD_DIFFERENT
    }

    error InvalidFixtureHeight(uint64 height);
    error FixtureHeightUnavailable(uint64 requested, uint64 available);
    error FixtureStatesMustDiffer();

    uint64 private _fixtureMaxHeight;
    Machine.Hash private _sameState;
    Machine.Hash private _rightmostState;
    Machine.Hash private _firstState;

    // Entry h is the root of a height-h subtree with the described shape.
    Tree.Node[] private _sameNodes;
    Tree.Node[] private _rightmostNodes;
    Tree.Node[] private _secondDifferentNodes;
    Tree.Node[] private _firstDifferentNodes;
    Tree.Node[] private _thirdDifferentNodes;

    /// @dev Initializes every family through maxHeight, inclusively.
    /// Reinitialization is supported so a test can select its own geometry.
    function initializeCommitmentFixture(
        uint64 maxHeight,
        Machine.Hash sameState_,
        Machine.Hash rightmostState_,
        Machine.Hash firstState_
    ) internal {
        if (maxHeight == 0 || maxHeight >= 256) {
            revert InvalidFixtureHeight(maxHeight);
        }

        bytes32 sameHash = Machine.Hash.unwrap(sameState_);
        bytes32 rightmostHash = Machine.Hash.unwrap(rightmostState_);
        bytes32 firstHash = Machine.Hash.unwrap(firstState_);
        if (
            sameHash == rightmostHash || sameHash == firstHash
                || rightmostHash == firstHash
        ) {
            revert FixtureStatesMustDiffer();
        }

        delete _sameNodes;
        delete _rightmostNodes;
        delete _secondDifferentNodes;
        delete _firstDifferentNodes;
        delete _thirdDifferentNodes;

        _fixtureMaxHeight = maxHeight;
        _sameState = sameState_;
        _rightmostState = rightmostState_;
        _firstState = firstState_;

        _sameNodes.push(Tree.Node.wrap(sameHash));
        _rightmostNodes.push(Tree.Node.wrap(rightmostHash));
        _secondDifferentNodes.push(Tree.Node.wrap(sameHash));
        _firstDifferentNodes.push(Tree.Node.wrap(firstHash));
        _thirdDifferentNodes.push(Tree.Node.wrap(firstHash));

        for (uint64 height = 1; height <= maxHeight; ++height) {
            Tree.Node sameChild = _sameNodes[height - 1];
            _sameNodes.push(sameChild.join(sameChild));
            _rightmostNodes.push(sameChild.join(_rightmostNodes[height - 1]));
            if (height == 1) {
                _secondDifferentNodes.push(sameChild.join(_rightmostNodes[0]));
            } else {
                _secondDifferentNodes.push(
                    _secondDifferentNodes[height - 1].join(sameChild)
                );
            }
            _firstDifferentNodes.push(
                _firstDifferentNodes[height - 1].join(sameChild)
            );
            if (height == 1) {
                _thirdDifferentNodes.push(_firstDifferentNodes[height]);
            } else if (height == 2) {
                _thirdDifferentNodes.push(
                    sameChild.join(_thirdDifferentNodes[height - 1])
                );
            } else {
                _thirdDifferentNodes.push(
                    _thirdDifferentNodes[height - 1].join(sameChild)
                );
            }
        }
    }

    function fixtureMaxHeight() internal view returns (uint64) {
        return _fixtureMaxHeight;
    }

    /// @dev Root of a subtree in which every leaf is sameState().
    function sameNode(uint64 height) internal view returns (Tree.Node) {
        _requireAvailable(height);
        return _sameNodes[height];
    }

    /// @dev Root of a subtree whose rightmost leaf is rightmostState().
    function rightmostNode(uint64 height) internal view returns (Tree.Node) {
        _requireAvailable(height);
        return _rightmostNodes[height];
    }

    /// @dev Root whose second leaf is rightmostState(). At height one this is
    /// the rightmost leaf; above height one its final state is sameState().
    function secondDifferentNode(uint64 height)
        internal
        view
        returns (Tree.Node)
    {
        _requireAvailable(height);
        return _secondDifferentNodes[height];
    }

    /// @dev Root of a subtree whose first (leftmost) leaf is firstState().
    /// Its final state is still sameState() for every positive height.
    function firstDifferentNode(uint64 height)
        internal
        view
        returns (Tree.Node)
    {
        _requireAvailable(height);
        return _firstDifferentNodes[height];
    }

    /// @dev Root whose third leaf differs at height two and above. At height
    /// one the first leaf differs, which is the selected subtree at the end of
    /// the same bisection path.
    function thirdDifferentNode(uint64 height)
        internal
        view
        returns (Tree.Node)
    {
        _requireAvailable(height);
        return _thirdDifferentNodes[height];
    }

    function node(CommitmentShape shape, uint64 height)
        internal
        view
        returns (Tree.Node)
    {
        if (shape == CommitmentShape.SAME) return sameNode(height);
        if (shape == CommitmentShape.RIGHTMOST_DIFFERENT) {
            return rightmostNode(height);
        }
        if (shape == CommitmentShape.SECOND_DIFFERENT) {
            return secondDifferentNode(height);
        }
        if (shape == CommitmentShape.FIRST_DIFFERENT) {
            return firstDifferentNode(height);
        }
        assert(shape == CommitmentShape.THIRD_DIFFERENT);
        return thirdDifferentNode(height);
    }

    /// @dev Returns the children of the selected height-h subtree root.
    function children(CommitmentShape shape, uint64 height)
        internal
        view
        returns (Tree.Node left, Tree.Node right)
    {
        _requirePositiveAvailable(height);
        uint64 childHeight = height - 1;

        if (shape == CommitmentShape.SAME) {
            left = sameNode(childHeight);
            right = left;
        } else if (shape == CommitmentShape.RIGHTMOST_DIFFERENT) {
            left = sameNode(childHeight);
            right = rightmostNode(childHeight);
        } else if (shape == CommitmentShape.SECOND_DIFFERENT) {
            if (height == 1) {
                left = sameNode(0);
                right = rightmostNode(0);
            } else {
                left = secondDifferentNode(childHeight);
                right = sameNode(childHeight);
            }
        } else if (shape == CommitmentShape.FIRST_DIFFERENT) {
            left = firstDifferentNode(childHeight);
            right = sameNode(childHeight);
        } else {
            assert(shape == CommitmentShape.THIRD_DIFFERENT);
            if (height == 1) {
                left = thirdDifferentNode(0);
                right = sameNode(0);
            } else if (height == 2) {
                left = sameNode(childHeight);
                right = thirdDifferentNode(childHeight);
            } else {
                left = thirdDifferentNode(childHeight);
                right = sameNode(childHeight);
            }
        }
    }

    function sameState() internal view returns (Machine.Hash) {
        return _sameState;
    }

    function rightmostState() internal view returns (Machine.Hash) {
        return _rightmostState;
    }

    function firstState() internal view returns (Machine.Hash) {
        return _firstState;
    }

    /// @dev Final state committed by the selected positive-height tree.
    function finalState(CommitmentShape shape, uint64 height)
        internal
        view
        returns (Machine.Hash)
    {
        _requirePositiveAvailable(height);
        if (
            shape == CommitmentShape.RIGHTMOST_DIFFERENT
                || (shape == CommitmentShape.SECOND_DIFFERENT && height == 1)
        ) {
            return _rightmostState;
        }
        return _sameState;
    }

    /// @dev Merkle proof for the final leaf of the selected tree.
    function finalProof(CommitmentShape shape, uint64 height)
        internal
        view
        returns (bytes32[] memory proof)
    {
        _requirePositiveAvailable(height);
        proof = _sameProof(height);

        if (shape == CommitmentShape.FIRST_DIFFERENT) {
            proof[height - 1] = Tree.Node.unwrap(firstDifferentNode(height - 1));
        } else if (shape == CommitmentShape.SECOND_DIFFERENT && height > 1) {
            proof[height - 1] =
                Tree.Node.unwrap(secondDifferentNode(height - 1));
        } else if (shape == CommitmentShape.THIRD_DIFFERENT) {
            if (height <= 2) {
                proof[0] = Tree.Node.unwrap(thirdDifferentNode(0));
            } else {
                proof[height - 1] =
                    Tree.Node.unwrap(thirdDifferentNode(height - 1));
            }
        }
    }

    /// @dev Merkle proof for leaf 2^height - 2 of the selected tree.
    /// This is the agree-state proof when SAME and RIGHTMOST_DIFFERENT are
    /// bisected down their rightmost branch.
    function agreeProofForSecondLast(CommitmentShape shape, uint64 height)
        internal
        view
        returns (bytes32[] memory proof)
    {
        _requirePositiveAvailable(height);
        proof = _sameProof(height);

        if (shape == CommitmentShape.RIGHTMOST_DIFFERENT) {
            proof[0] = Tree.Node.unwrap(rightmostNode(0));
        } else if (shape == CommitmentShape.SECOND_DIFFERENT) {
            if (height == 1) {
                proof[0] = Tree.Node.unwrap(rightmostNode(0));
            } else {
                proof[height - 1] =
                    Tree.Node.unwrap(secondDifferentNode(height - 1));
            }
        } else if (shape == CommitmentShape.FIRST_DIFFERENT && height > 1) {
            proof[height - 1] = Tree.Node.unwrap(firstDifferentNode(height - 1));
        } else if (shape == CommitmentShape.THIRD_DIFFERENT && height > 2) {
            proof[height - 1] = Tree.Node.unwrap(thirdDifferentNode(height - 1));
        }
    }

    /// @dev State at leaf 2^height - 2, paired with the agree proof above.
    function secondLastState(CommitmentShape shape, uint64 height)
        internal
        view
        returns (Machine.Hash)
    {
        _requirePositiveAvailable(height);
        if (
            (shape == CommitmentShape.FIRST_DIFFERENT && height == 1)
                || (shape == CommitmentShape.THIRD_DIFFERENT && height <= 2)
        ) {
            return _firstState;
        }
        return _sameState;
    }

    function _sameProof(uint64 height)
        private
        view
        returns (bytes32[] memory proof)
    {
        proof = new bytes32[](height);
        for (uint64 level; level < height; ++level) {
            proof[level] = Tree.Node.unwrap(sameNode(level));
        }
    }

    function _requirePositiveAvailable(uint64 height) private view {
        if (height == 0) revert InvalidFixtureHeight(height);
        _requireAvailable(height);
    }

    function _requireAvailable(uint64 height) private view {
        if (height > _fixtureMaxHeight || _sameNodes.length == 0) {
            revert FixtureHeightUnavailable(height, _fixtureMaxHeight);
        }
    }
}
