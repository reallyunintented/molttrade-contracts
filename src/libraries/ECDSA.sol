// SPDX-License-Identifier: MPL-2.0
pragma solidity 0.8.24;

library ECDSA {
    uint256 private constant SECP256K1N_HALVED =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS
    }

    function tryRecover(bytes32 hash, bytes calldata signature)
        internal
        pure
        returns (address recovered, RecoverError error, bytes32 errorArg)
    {
        if (signature.length != 65) {
            return (address(0), RecoverError.InvalidSignatureLength, bytes32(signature.length));
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        return tryRecover(hash, v, r, s);
    }

    function tryRecover(bytes32 hash, uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (address recovered, RecoverError error, bytes32 errorArg)
    {
        if (uint256(s) > SECP256K1N_HALVED) {
            return (address(0), RecoverError.InvalidSignatureS, s);
        }
        if (v != 27 && v != 28) {
            return (address(0), RecoverError.InvalidSignature, bytes32(uint256(v)));
        }

        recovered = ecrecover(hash, v, r, s);
        if (recovered == address(0)) {
            return (address(0), RecoverError.InvalidSignature, bytes32(0));
        }

        return (recovered, RecoverError.NoError, bytes32(0));
    }
}
