;; Title: BitSwap - Bitcoin-Native Automated Market Maker Protocol
;;
;; Summary: A decentralized exchange protocol built on Stacks Layer 2 that enables 
;; trustless token swaps with minimal slippage and capital-efficient liquidity provision.
;;
;; Description: BitSwap implements a constant-product market maker algorithm (x*y=k) 
;; with advanced liquidity management features. The protocol supports multiple token pair 
;; pools, customizable fees, and built-in protection mechanisms to ensure fair and 
;; efficient trading for Bitcoin and Stacks ecosystem assets.

;; Define the trait for fungible tokens
(define-trait ft-trait (
  (transfer
    (uint principal principal)
    (response bool uint)
  )
  (get-balance
    (principal)
    (response uint uint)
  )
  (get-total-supply
    ()
    (response uint uint)
  )
  (get-decimals
    ()
    (response uint uint)
  )
  (get-name
    ()
    (response (string-ascii 32) uint)
  )
  (get-symbol
    ()
    (response (string-ascii 32) uint)
  )
))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-INSUFFICIENT-BALANCE (err u102))
(define-constant ERR-POOL-NOT-FOUND (err u103))
(define-constant ERR-INVALID-POOL (err u104))
(define-constant ERR-SLIPPAGE-TOO-HIGH (err u105))
(define-constant ERR-ZERO-LIQUIDITY (err u106))
(define-constant PRECISION u1000000) ;; 6 decimal places for price calculations

;; Helper Functions
(define-private (mul
    (a uint)
    (b uint)
  )
  (* a b)
)

(define-private (min
    (a uint)
    (b uint)
  )
  (if (<= a b)
    a
    b
  )
)

;; Data Variables
(define-data-var protocol-fee-rate uint u3000) ;; 0.3% fee
(define-data-var total-pools uint u0)

;; Data Maps
(define-map pools
  uint
  {
    token-x: principal,
    token-y: principal,
    reserve-x: uint,
    reserve-y: uint,
    total-shares: uint,
    active: bool,
  }
)

(define-map liquidity-providers
  {
    pool-id: uint,
    provider: principal,
  }
  { shares: uint }
)

(define-map accumulated-fees
  principal
  uint
)

;; Private Functions
(define-private (calculate-output-amount
    (input-amount uint)
    (input-reserve uint)
    (output-reserve uint)
  )
  (let (
      (input-with-fee (mul input-amount (- PRECISION (var-get protocol-fee-rate))))
      (numerator (mul input-with-fee output-reserve))
      (denominator (+ (mul input-reserve PRECISION) input-with-fee))
    )
    (/ numerator denominator)
  )
)

(define-private (mint-pool-tokens
    (pool-id uint)
    (amount-x uint)
    (amount-y uint)
    (recipient principal)
  )
  (let (
      (pool (unwrap! (map-get? pools pool-id) ERR-POOL-NOT-FOUND))
      (total-shares (get total-shares pool))
      (shares-to-mint (if (is-eq total-shares u0)
        (mul amount-x amount-y)
        (min (/ (mul amount-x total-shares) (get reserve-x pool))
          (/ (mul amount-y total-shares) (get reserve-y pool))
        )
      ))
    )
    (map-set pools pool-id
      (merge pool {
        reserve-x: (+ (get reserve-x pool) amount-x),
        reserve-y: (+ (get reserve-y pool) amount-y),
        total-shares: (+ total-shares shares-to-mint),
      })
    )
    (map-set liquidity-providers {
      pool-id: pool-id,
      provider: recipient,
    } { shares: (+
      (default-to u0
        (get shares
          (map-get? liquidity-providers {
            pool-id: pool-id,
            provider: recipient,
          })
        ))
      shares-to-mint
    ) }
    )
    (ok shares-to-mint)
  )
)

;; Public Functions

;; Creates a new liquidity pool for a pair of tokens
(define-public (create-pool
    (token-x <ft-trait>)
    (token-y <ft-trait>)
  )
  (let (
      (pool-id (var-get total-pools))
      (token-x-principal (contract-of token-x))
      (token-y-principal (contract-of token-y))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-eq token-x-principal token-y-principal)) ERR-INVALID-POOL)
    (map-set pools pool-id {
      token-x: token-x-principal,
      token-y: token-y-principal,
      reserve-x: u0,
      reserve-y: u0,
      total-shares: u0,
      active: true,
    })
    (var-set total-pools (+ pool-id u1))
    (ok pool-id)
  )
)

;; Adds liquidity to an existing pool
(define-public (add-liquidity
    (pool-id uint)
    (token-x <ft-trait>)
    (token-y <ft-trait>)
    (amount-x uint)
    (amount-y uint)
    (min-shares uint)
  )
  (let (
      (pool (unwrap! (map-get? pools pool-id) ERR-POOL-NOT-FOUND))
      (token-x-principal (contract-of token-x))
      (token-y-principal (contract-of token-y))
    )
    (asserts! (> amount-x u0) ERR-INVALID-AMOUNT)
    (asserts! (> amount-y u0) ERR-INVALID-AMOUNT)
    (asserts! (get active pool) ERR-POOL-NOT-FOUND)
    (asserts! (is-eq token-x-principal (get token-x pool)) ERR-INVALID-POOL)
    (asserts! (is-eq token-y-principal (get token-y pool)) ERR-INVALID-POOL)
    ;; Transfer tokens to pool
    (try! (contract-call? token-x transfer amount-x tx-sender (as-contract tx-sender)))
    (try! (contract-call? token-y transfer amount-y tx-sender (as-contract tx-sender)))
    ;; Mint LP tokens
    (let ((shares (unwrap! (mint-pool-tokens pool-id amount-x amount-y tx-sender)
        ERR-INVALID-AMOUNT
      )))
      (asserts! (>= shares min-shares) ERR-SLIPPAGE-TOO-HIGH)
      (ok shares)
    )
  )
)

;; Executes a token swap with exact input amount
(define-public (swap-exact-tokens
    (pool-id uint)
    (token-in <ft-trait>)
    (token-out <ft-trait>)
    (amount-in uint)
    (min-amount-out uint)
    (x-to-y bool)
  )
  (let (
      (pool (unwrap! (map-get? pools pool-id) ERR-POOL-NOT-FOUND))
      (token-in-principal (contract-of token-in))
      (token-out-principal (contract-of token-out))
      (input-reserve (if x-to-y
        (get reserve-x pool)
        (get reserve-y pool)
      ))
      (output-reserve (if x-to-y
        (get reserve-y pool)
        (get reserve-x pool)
      ))
    )
    (asserts! (> amount-in u0) ERR-INVALID-AMOUNT)
    (asserts! (get active pool) ERR-POOL-NOT-FOUND)
    (asserts!
      (is-eq token-in-principal
        (if x-to-y
          (get token-x pool)
          (get token-y pool)
        ))
      ERR-INVALID-POOL
    )
    (asserts!
      (is-eq token-out-principal
        (if x-to-y
          (get token-y pool)
          (get token-x pool)
        ))
      ERR-INVALID-POOL
    )
    (let ((amount-out (calculate-output-amount amount-in input-reserve output-reserve)))
      (asserts! (>= amount-out min-amount-out) ERR-SLIPPAGE-TOO-HIGH)
      ;; Transfer input tokens to pool
      (try! (contract-call? token-in transfer amount-in tx-sender
        (as-contract tx-sender)
      ))
      ;; Transfer output tokens to user
      (as-contract (try! (contract-call? token-out transfer amount-out (as-contract tx-sender)
        tx-sender
      )))
      ;; Update pool reserves
      (map-set pools pool-id
        (merge pool
          (if x-to-y
            {
              reserve-x: (+ input-reserve amount-in),
              reserve-y: (- output-reserve amount-out),
            }
            {
              reserve-x: (- output-reserve amount-out),
              reserve-y: (+ input-reserve amount-in),
            }
          ))
      )
      (ok amount-out)
    )
  )
)