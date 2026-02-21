;; Crowdfund Escrow Contract
;; Secure fund holding during crowdfund campaigns
;; Releases funds on success, refunds on failure

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u700))
(define-constant err-not-authorized (err u701))
(define-constant err-not-found (err u702))
(define-constant err-escrow-locked (err u703))
(define-constant err-escrow-empty (err u704))
(define-constant err-invalid-state (err u705))
(define-constant err-insufficient-funds (err u706))

(define-constant ESCROW-FEE-BPS u100) ;; 1% escrow fee

(define-data-var escrow-count uint u0)
(define-data-var total-held uint u0)
(define-data-var total-released uint u0)
(define-data-var total-refunded uint u0)

;; Escrow accounts
(define-map escrows uint
  {
    campaign-id: uint,
    beneficiary: principal,
    amount: uint,
    fee: uint,
    deposited-at: uint,
    release-condition: uint,  ;; 0=manual, 1=goal-met, 2=time-locked
    status: uint,             ;; 0=holding, 1=released, 2=refunded, 3=disputed
    release-block: (optional uint),
    released-at: (optional uint)
  }
)

;; Escrow deposits by contributor
(define-map escrow-deposits
  { escrow-id: uint, depositor: principal }
  { amount: uint, deposited-at: uint, refunded: bool }
)

(define-map campaign-escrow uint uint) ;; campaign-id -> escrow-id

;; Read-only
(define-read-only (get-escrow (escrow-id uint))
  (map-get? escrows escrow-id)
)

(define-read-only (get-campaign-escrow (campaign-id uint))
  (match (map-get? campaign-escrow campaign-id)
    escrow-id (map-get? escrows escrow-id)
    none
  )
)

(define-read-only (get-deposit (escrow-id uint) (depositor principal))
  (map-get? escrow-deposits { escrow-id: escrow-id, depositor: depositor })
)

(define-read-only (get-escrow-fee (amount uint))
  (/ (* amount ESCROW-FEE-BPS) u10000)
)

(define-read-only (get-total-held)
  (var-get total-held)
)

;; Public functions
(define-public (create-escrow
    (campaign-id uint)
    (beneficiary principal)
    (release-condition uint)
    (release-block (optional uint)))
  (let ((escrow-id (var-get escrow-count)))
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-none (map-get? campaign-escrow campaign-id)) err-invalid-state)

    (map-set escrows escrow-id {
      campaign-id: campaign-id,
      beneficiary: beneficiary,
      amount: u0,
      fee: u0,
      deposited-at: stacks-block-height,
      release-condition: release-condition,
      status: u0,
      release-block: release-block,
      released-at: none
    })

    (map-set campaign-escrow campaign-id escrow-id)
    (var-set escrow-count (+ escrow-id u1))
    (ok { escrow-id: escrow-id, campaign-id: campaign-id })
  )
)

(define-public (deposit-to-escrow (escrow-id uint) (amount uint))
  (match (map-get? escrows escrow-id)
    escrow
    (begin
      (asserts! (is-eq (get status escrow) u0) err-escrow-locked)
      (asserts! (> amount u0) err-insufficient-funds)

      (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))

      (let ((existing (map-get? escrow-deposits { escrow-id: escrow-id, depositor: tx-sender })))
        (map-set escrow-deposits
          { escrow-id: escrow-id, depositor: tx-sender }
          {
            amount: (+ amount (match existing e (get amount e) u0)),
            deposited-at: stacks-block-height,
            refunded: false
          }
        )
        (map-set escrows escrow-id (merge escrow { amount: (+ (get amount escrow) amount) }))
        (var-set total-held (+ (var-get total-held) amount))
        (ok { escrow-id: escrow-id, deposited: amount, total: (+ (get amount escrow) amount) })
      )
    )
    err-not-found
  )
)

(define-public (release-funds (escrow-id uint))
  (match (map-get? escrows escrow-id)
    escrow
    (let (
      (fee (get-escrow-fee (get amount escrow)))
      (net (- (get amount escrow) fee))
    )
      (asserts! (is-eq tx-sender contract-owner) err-owner-only)
      (asserts! (is-eq (get status escrow) u0) err-escrow-locked)
      (asserts! (> (get amount escrow) u0) err-escrow-empty)

      (try! (as-contract (stx-transfer? net tx-sender (get beneficiary escrow))))
      (try! (as-contract (stx-transfer? fee tx-sender contract-owner)))

      (map-set escrows escrow-id (merge escrow {
        status: u1,
        fee: fee,
        released-at: (some stacks-block-height)
      }))

      (var-set total-held (- (var-get total-held) (get amount escrow)))
      (var-set total-released (+ (var-get total-released) net))

      (ok { released: net, fee: fee, beneficiary: (get beneficiary escrow) })
    )
    err-not-found
  )
)

(define-public (refund-from-escrow (escrow-id uint) (depositor principal))
  (match (map-get? escrows escrow-id)
    escrow
    (match (map-get? escrow-deposits { escrow-id: escrow-id, depositor: depositor })
      deposit
      (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (not (get refunded deposit)) err-invalid-state)
        (asserts! (> (get amount deposit) u0) err-escrow-empty)

        (try! (as-contract (stx-transfer? (get amount deposit) tx-sender depositor)))

        (map-set escrow-deposits
          { escrow-id: escrow-id, depositor: depositor }
          (merge deposit { refunded: true })
        )

        (map-set escrows escrow-id (merge escrow {
          amount: (- (get amount escrow) (get amount deposit)),
          status: u2
        }))

        (var-set total-held (- (var-get total-held) (get amount deposit)))
        (var-set total-refunded (+ (var-get total-refunded) (get amount deposit)))

        (ok { refunded: (get amount deposit), depositor: depositor })
      )
      err-not-found
    )
    err-not-found
  )
)

(define-public (dispute-escrow (escrow-id uint) (reason (string-ascii 100)))
  (match (map-get? escrows escrow-id)
    escrow
    (begin
      (asserts! (or (is-eq tx-sender (get beneficiary escrow)) (is-eq tx-sender contract-owner)) err-not-authorized)
      (asserts! (is-eq (get status escrow) u0) err-escrow-locked)
      (map-set escrows escrow-id (merge escrow { status: u3 }))
      (ok { escrow-id: escrow-id, disputed: true })
    )
    err-not-found
  )
)
