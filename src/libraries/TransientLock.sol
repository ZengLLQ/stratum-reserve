// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TransientLock
 * @notice Gas-optimized transient storage reentrancy guard for Cancun EVM (EIP-1153).
 *         Replaces cold SSTORE/SLOAD with transient TSTORE/TLOAD (100 gas vs 2100+ gas).
 */
abstract contract TransientLock {
    // keccak256("stratum.transient.lock.slot") - 1
    bytes32 private constant TRANSIENT_LOCK_SLOT = 0x7f48e3532c5896328a6fcf7c53d455bb3a2df432c25e83e9206b12a52efc1878;

    error TransientLock__ReentrantCall();

    modifier nonReentrant() {
        _enterTransient();
        _;
        _exitTransient();
    }

    function _enterTransient() internal {
        assembly {
            if tload(TRANSIENT_LOCK_SLOT) {
                // Revert with TransientLock__ReentrantCall()
                mstore(0x00, 0xb8021d96) // 4-byte selector of TransientLock__ReentrantCall()
                revert(0x1c, 0x04)
            }
            tstore(TRANSIENT_LOCK_SLOT, 1)
        }
    }

    function _exitTransient() internal {
        assembly {
            tstore(TRANSIENT_LOCK_SLOT, 0)
        }
    }
}
