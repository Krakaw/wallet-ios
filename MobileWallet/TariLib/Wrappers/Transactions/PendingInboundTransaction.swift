//  PendingInboundTransaction.swift

/*
	Package MobileWallet
	Created by Jason van den Berg on 2019/11/18
	Using Swift 5.0
	Running on macOS 10.15

	Copyright 2019 The Tari Project

	Redistribution and use in source and binary forms, with or
	without modification, are permitted provided that the
	following conditions are met:

	1. Redistributions of source code must retain the above copyright notice,
	this list of conditions and the following disclaimer.

	2. Redistributions in binary form must reproduce the above
	copyright notice, this list of conditions and the following disclaimer in the
	documentation and/or other materials provided with the distribution.

	3. Neither the name of the copyright holder nor the names of
	its contributors may be used to endorse or promote products
	derived from this software without specific prior written permission.

	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
	CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
	INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
	OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
	DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
	CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
	SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
	NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
	LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
	HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
	CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
	OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
	SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

import Foundation

enum PendingInboundTransactionStatus: Error {
    case transactionNullError
    case completed
    case broadcast
    case mined
    case imported
    case pending
    case unknown
}

enum PendingInboundTransactionError: Error {
    case generic(_ errorCode: Int32)
}

class PendingInboundTransaction: TransactionProtocol {
    var cachedContact: Contact?

    var destinationPublicKey: (PublicKey?, Error?)

    private var ptr: OpaquePointer

    var direction: TransactionDirection = .inbound

    var pointer: OpaquePointer {
        return ptr
    }

    var id: (UInt64, Error?) {
        var errorCode: Int32 = -1
        let result = pending_inbound_transaction_get_transaction_id(ptr, UnsafeMutablePointer<Int32>(&errorCode))
        return (result, errorCode != 0 ? PendingInboundTransactionError.generic(errorCode) : nil)
    }

    var microTari: (MicroTari?, Error?) {
        var errorCode: Int32 = -1
        let result = pending_inbound_transaction_get_amount(ptr, UnsafeMutablePointer<Int32>(&errorCode))

        guard errorCode == 0 else {
            return (nil, CompletedTransactionError.generic(errorCode))
        }

        return (MicroTari(result), nil)
    }

    var message: (String, Error?) {
        var errorCode: Int32 = -1
        let resultPtr = pending_inbound_transaction_get_message(ptr, UnsafeMutablePointer<Int32>(&errorCode))
        let result = String(cString: resultPtr!)

        let mutable = UnsafeMutablePointer<Int8>(mutating: resultPtr!)
        string_destroy(mutable)

        return (result, errorCode != 0 ? PendingInboundTransactionError.generic(errorCode) : nil)
    }

    var timestamp: (UInt64, Error?) {
        var errorCode: Int32 = -1
        let result = pending_inbound_transaction_get_timestamp(ptr, UnsafeMutablePointer<Int32>(&errorCode))
        return (result, errorCode != 0 ? PendingInboundTransactionError.generic(errorCode) : nil)
    }

    var sourcePublicKey: (PublicKey?, Error?) {
        var errorCode: Int32 = -1
        let err = UnsafeMutablePointer<Int32>(&errorCode)
        let resultPointer = pending_inbound_transaction_get_source_public_key(ptr, err)
        guard errorCode == 0 else {
            return (nil, PendingInboundTransactionError.generic(errorCode))
        }

        return (PublicKey(pointer: resultPointer!), nil)
    }

    var status: (PendingInboundTransactionStatus, Error?) {
        var errorCode: Int32 = -1
        let status: Int32 = pending_inbound_transaction_get_status(ptr, UnsafeMutablePointer<Int32>(&errorCode))
        guard errorCode == 0 else {
            return (.unknown, PendingInboundTransactionError.generic(errorCode))
        }

    switch status {
            case -1:
                return (.transactionNullError, nil)
            case 0:
                return (.completed, nil)
            case 1:
                return (.broadcast, nil)
            case 2:
                return (.mined, nil)
            case 3:
                 return (.imported, nil)
            case 4:
                 return (.pending, nil)
            default:
                return (.unknown, nil)
        }
    }

    var contact: (Contact?, Error?) {
        if cachedContact != nil {
            return (cachedContact, nil)
        }

        guard let wallet = TariLib.shared.tariWallet else {
            return (nil, WalletErrors.walletNotInitialized)
        }

        let (contacts, contactsError) = wallet.contacts
        guard contactsError == nil else {
            return (nil, contactsError)
        }

        let (pubKey, pubKeyError) = sourcePublicKey
        guard pubKeyError == nil else {
            return (nil, pubKeyError)
        }

        do {
            cachedContact = try contacts!.find(publicKey: pubKey!)
            return (cachedContact, nil)
        } catch {
            return (nil, error)
        }
    }

    init(pendingInboundTransactionPointer: OpaquePointer) {
        ptr = pendingInboundTransactionPointer
    }

    deinit {
        pending_inbound_transaction_destroy(ptr)
    }
}
