;; Crowdfund Platform Token Contract
;; SIP-010 governance and utility token for crowdfund platform
;; Used for fee discounts, governance voting, and staking

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u900))
(define-constant err-not-authorized (err u901))
(define-constant err-insufficient-balance (err u902))
(define-constant err-invalid-amount (err u903))

(define-constant TOKEN-NAME "Stacks Crowdfund Token")
(define-constant TOKEN-SYMBOL "SCT")
(define-constant TOKEN-DECIMALS u6)
(define-constant INITIAL-SUPPLY u500000000000000) ;; 500M tokens
(define-constant MAX-SUPPLY u1000000000000000)    ;; 1B max

(define-data-var total-supply uint u0)
(define-data-var minting-active bool true)
(define-data-var paused bool false)

(define-map balances principal uint)
(define-map allowances { owner: principal, spender: principal } uint)
(define-map minters principal bool)

;; SIP-010 read-only
(define-read-only (get-name) (ok TOKEN-NAME))
(define-read-only (get-symbol) (ok TOKEN-SYMBOL))
(define-read-only (get-decimals) (ok TOKEN-DECIMALS))
(define-read-only (get-total-supply) (ok (var-get total-supply)))

(define-read-only (get-balance (account principal))
  (ok (default-to u0 (map-get? balances account)))
)

(define-read-only (get-allowance (owner principal) (spender principal))
  (ok (default-to u0 (map-get? allowances { owner: owner, spender: spender })))
)

(define-read-only (get-token-uri)
  (ok (some u"https://stacks-crowdfund.xyz/token"))
)

;; Public functions
(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (not (var-get paused)) err-not-authorized)
    (asserts! (is-eq tx-sender sender) err-not-authorized)
    (asserts! (> amount u0) err-invalid-amount)
    (let ((bal (default-to u0 (map-get? balances sender))))
      (asserts! (>= bal amount) err-insufficient-balance)
      (map-set balances sender (- bal amount))
      (map-set balances recipient (+ (default-to u0 (map-get? balances recipient)) amount))
      (match memo m (print m) true)
      (ok true)
    )
  )
)

(define-public (approve (spender principal) (amount uint))
  (begin
    (map-set allowances { owner: tx-sender, spender: spender } amount)
    (ok true)
  )
)

(define-public (transfer-from (amount uint) (owner principal) (recipient principal))
  (let (
    (allow (default-to u0 (map-get? allowances { owner: owner, spender: tx-sender })))
    (bal (default-to u0 (map-get? balances owner)))
  )
    (asserts! (>= allow amount) err-not-authorized)
    (asserts! (>= bal amount) err-insufficient-balance)
    (map-set balances owner (- bal amount))
    (map-set balances recipient (+ (default-to u0 (map-get? balances recipient)) amount))
    (map-set allowances { owner: owner, spender: tx-sender } (- allow amount))
    (ok true)
  )
)

(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (or (is-eq tx-sender contract-owner) (default-to false (map-get? minters tx-sender))) err-owner-only)
    (asserts! (var-get minting-active) err-not-authorized)
    (asserts! (<= (+ (var-get total-supply) amount) MAX-SUPPLY) err-invalid-amount)
    (map-set balances recipient (+ (default-to u0 (map-get? balances recipient)) amount))
    (var-set total-supply (+ (var-get total-supply) amount))
    (ok { minted: amount, total: (var-get total-supply) })
  )
)

(define-public (burn (amount uint))
  (let ((bal (default-to u0 (map-get? balances tx-sender))))
    (asserts! (>= bal amount) err-insufficient-balance)
    (map-set balances tx-sender (- bal amount))
    (var-set total-supply (- (var-get total-supply) amount))
    (ok { burned: amount })
  )
)

(define-public (add-minter (minter principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set minters minter true)
    (ok minter)
  )
)

(define-public (initialize)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-eq (var-get total-supply) u0) err-not-authorized)
    (map-set balances contract-owner INITIAL-SUPPLY)
    (var-set total-supply INITIAL-SUPPLY)
    (ok { initial-supply: INITIAL-SUPPLY, owner: contract-owner })
  )
)

(define-public (toggle-pause (status bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set paused status)
    (ok status)
  )
)
