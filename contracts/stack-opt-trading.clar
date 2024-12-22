;; Title: Stack Options Trading Smart Contract

;; Summary:
;; This smart contract facilitates the creation, trading, and exercising of options on the Stacks blockchain.
;; It adheres to the SIP-010 token standard for token interactions and includes various functionalities for managing options, user positions, and price feeds.

;; Description:
;; The Stack Options Trading smart contract allows users to write, buy, and exercise options using SIP-010 compliant tokens.
;; It includes mechanisms for validating inputs, managing user positions, and integrating with price oracles.
;; The contract also provides governance features for managing protocol parameters and approved tokens.
;; Error handling is implemented through predefined error codes to ensure robust and secure operations.

;; Constants

;; SIP-010 Fungible Token Interface
(define-trait sip-010-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-balance (principal) (response uint uint))
    (get-total-supply () (response uint uint))
    (get-decimals () (response uint uint))
    (get-token-uri () (response (optional (string-utf8 256)) uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 32) uint))
  )
)

;; Error Constants
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-INSUFFICIENT-BALANCE (err u1001))
(define-constant ERR-INVALID-EXPIRY (err u1002))
(define-constant ERR-INVALID-STRIKE-PRICE (err u1003))
(define-constant ERR-OPTION-NOT-FOUND (err u1004))
(define-constant ERR-OPTION-EXPIRED (err u1005))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u1006))
(define-constant ERR-ALREADY-EXERCISED (err u1007))
(define-constant ERR-INVALID-PREMIUM (err u1008))
(define-constant ERR-INVALID-TOKEN (err u1009))
(define-constant ERR-INVALID-SYMBOL (err u1010))
(define-constant ERR-INVALID-TIMESTAMP (err u1011))
(define-constant ERR-INVALID-ADDRESS (err u1012))
(define-constant ERR-ZERO-ADDRESS (err u1013))

;; Data Maps and Vars

;; Options Data Map
(define-map options
  uint  ;; option-id
  {
    writer: principal,
    holder: (optional principal),
    collateral-amount: uint,
    strike-price: uint,
    premium: uint,
    expiry: uint,
    is-exercised: bool,
    option-type: (string-ascii 4),  ;; "CALL" or "PUT"
    state: (string-ascii 9)         ;; "ACTIVE" or "EXERCISED"
  }
)

;; User Positions Map
(define-map user-positions
  principal
  {
    written-options: (list 10 uint),
    held-options: (list 10 uint),
    total-collateral-locked: uint
  }
)

;; Approved Tokens Map
(define-map approved-tokens principal bool)

;; Price Feeds Map
(define-map price-feeds
  (string-ascii 10)
  {
    price: uint,
    timestamp: uint,
    source: principal
  }
)

;; Allowed Symbols Map
(define-map allowed-symbols (string-ascii 10) bool)

;; Contract Variables
(define-data-var next-option-id uint u1)
(define-data-var contract-owner principal tx-sender)
(define-data-var protocol-fee-rate uint u100) ;; 1% = 100 basis points

;; Private Functions

;; Utility function to get minimum of two numbers
(define-private (get-min (a uint) (b uint))
  (if (< a b) a b)
)

;; Validate collateral requirements for options
(define-private (check-collateral-requirement 
    (amount uint) 
    (strike uint) 
    (option-type (string-ascii 4)))
  (if (is-eq option-type "CALL")
    (>= amount strike)
    (>= amount (/ (* strike u100000000) (get-current-price)))
  )
)

;; Exercise a call option
(define-private (exercise-call
    (token <sip-010-trait>)
    (option {
      writer: principal,
      holder: (optional principal),
      collateral-amount: uint,
      strike-price: uint,
      premium: uint,
      expiry: uint,
      is-exercised: bool,
      option-type: (string-ascii 4),
      state: (string-ascii 9)
    })
    (current-price uint))
  (let (
    (profit (- current-price (get strike-price option)))
    (payout (get-min profit (get collateral-amount option)))
  )
    ;; Transfer payout to option holder
    (try! (as-contract (contract-call? token transfer
      payout
      tx-sender
      (unwrap! (get holder option) ERR-NOT-AUTHORIZED)
      none)))

    ;; Return remaining collateral to writer
    (try! (as-contract (contract-call? token transfer
      (- (get collateral-amount option) payout)
      tx-sender
      (get writer option)
      none)))

    ;; Update option state
    (map-set options (get-option-id option) (merge option {
      is-exercised: true,
      state: "EXERCISED"
    }))

    (ok true)
  )
)

;; Exercise a put option
(define-private (exercise-put
    (token <sip-010-trait>)
    (option {
      writer: principal,
      holder: (optional principal),
      collateral-amount: uint,
      strike-price: uint,
      premium: uint,
      expiry: uint,
      is-exercised: bool,
      option-type: (string-ascii 4),
      state: (string-ascii 9)
    })
    (current-price uint))
  (let (
    (profit (- (get strike-price option) current-price))
    (payout (get-min profit (get collateral-amount option)))
  )
    ;; Transfer payout to option holder
    (try! (as-contract (contract-call? token transfer
      payout
      tx-sender
      (unwrap! (get holder option) ERR-NOT-AUTHORIZED)
      none)))

    ;; Return remaining collateral to writer
    (try! (as-contract (contract-call? token transfer
      (- (get collateral-amount option) payout)
      tx-sender
      (get writer option)
      none)))

    ;; Update option state
    (map-set options (get-option-id option) (merge option {
      is-exercised: true,
      state: "EXERCISED"
    }))

    (ok true)
  )
)

;; Get current price from price feed
(define-private (get-current-price)
  (get price (unwrap! (map-get? price-feeds "BTC-USD") u0))
)

;; Get option ID helper
(define-private (get-option-id (option {
    writer: principal,
    holder: (optional principal),
    collateral-amount: uint,
    strike-price: uint,
    premium: uint,
    expiry: uint,
    is-exercised: bool,
    option-type: (string-ascii 4),
    state: (string-ascii 9)
  }))
  (var-get next-option-id)
)

;; Check if token is approved
(define-private (is-approved-token (token principal))
  (default-to false (map-get? approved-tokens token))
)

;; Check if symbol is allowed
(define-private (is-allowed-symbol (symbol (string-ascii 10)))
  (default-to false (map-get? allowed-symbols symbol))
)

;; Validate principal address
(define-private (is-valid-principal (address principal))
  (and
    (not (is-eq address (as-contract tx-sender)))
    (not (is-eq address .base))
    (not (is-eq address tx-sender))
    true
  )
)

;; Validate symbol format
(define-private (is-valid-symbol (symbol (string-ascii 10)))
  (and
    (not (is-eq symbol ""))
    (not (is-eq symbol " "))
    (>= (len symbol) u2)
  )
)

;; Check if token is critical
(define-private (is-critical-token (token principal))
  (or
    (is-eq token .wrapped-btc)
    (is-eq token .wrapped-stx)
  )
)

;; Check if symbol is critical
(define-private (is-critical-symbol (symbol (string-ascii 10)))
  (or
    (is-eq symbol "BTC-USD")
    (is-eq symbol "STX-USD")
  )
)