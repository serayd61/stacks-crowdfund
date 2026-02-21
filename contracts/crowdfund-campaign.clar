;; Crowdfund Campaign Contract
;; Decentralized crowdfunding on Stacks blockchain
;; All-or-nothing funding with automatic refunds

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-not-found (err u102))
(define-constant err-campaign-closed (err u103))
(define-constant err-goal-not-met (err u104))
(define-constant err-goal-met (err u105))
(define-constant err-already-claimed (err u106))
(define-constant err-invalid-amount (err u107))
(define-constant err-min-duration (err u108))

(define-constant MIN-GOAL u1000000)        ;; 1 STX min
(define-constant MIN-DURATION u144)        ;; ~1 day
(define-constant MAX-DURATION u20160)      ;; ~140 days
(define-constant PLATFORM-FEE-BPS u250)   ;; 2.5%

(define-data-var campaign-count uint u0)
(define-data-var total-raised uint u0)
(define-data-var platform-fees-collected uint u0)

;; Campaigns
(define-map campaigns uint
  {
    creator: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    category: (string-ascii 30),
    goal: uint,
    raised: uint,
    contributor-count: uint,
    start-block: uint,
    end-block: uint,
    status: uint,  ;; 0=active, 1=funded, 2=failed, 3=cancelled
    funds-claimed: bool,
    image-url: (string-ascii 200)
  }
)

;; Contributions
(define-map contributions
  { campaign-id: uint, contributor: principal }
  { amount: uint, contributed-at: uint, refunded: bool }
)

;; Read-only
(define-read-only (get-campaign (campaign-id uint))
  (map-get? campaigns campaign-id)
)

(define-read-only (get-contribution (campaign-id uint) (contributor principal))
  (map-get? contributions { campaign-id: campaign-id, contributor: contributor })
)

(define-read-only (is-campaign-active (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    c (and (is-eq (get status c) u0) (<= stacks-block-height (get end-block c)))
    false
  )
)

(define-read-only (is-campaign-funded (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    c (>= (get raised c) (get goal c))
    false
  )
)

(define-read-only (get-platform-fee (amount uint))
  (/ (* amount PLATFORM-FEE-BPS) u10000)
)

;; Public functions
(define-public (create-campaign
    (title (string-ascii 100))
    (description (string-ascii 500))
    (category (string-ascii 30))
    (goal uint)
    (duration-blocks uint)
    (image-url (string-ascii 200)))
  (let ((campaign-id (var-get campaign-count)))
    (asserts! (>= goal MIN-GOAL) err-invalid-amount)
    (asserts! (>= duration-blocks MIN-DURATION) err-min-duration)
    (asserts! (<= duration-blocks MAX-DURATION) err-min-duration)

    (map-set campaigns campaign-id {
      creator: tx-sender,
      title: title,
      description: description,
      category: category,
      goal: goal,
      raised: u0,
      contributor-count: u0,
      start-block: stacks-block-height,
      end-block: (+ stacks-block-height duration-blocks),
      status: u0,
      funds-claimed: false,
      image-url: image-url
    })

    (var-set campaign-count (+ campaign-id u1))
    (ok { campaign-id: campaign-id, goal: goal, end-block: (+ stacks-block-height duration-blocks) })
  )
)

(define-public (contribute (campaign-id uint) (amount uint))
  (match (map-get? campaigns campaign-id)
    campaign
    (begin
      (asserts! (is-campaign-active campaign-id) err-campaign-closed)
      (asserts! (> amount u0) err-invalid-amount)

      (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))

      (let ((existing (map-get? contributions { campaign-id: campaign-id, contributor: tx-sender })))
        (map-set contributions
          { campaign-id: campaign-id, contributor: tx-sender }
          {
            amount: (+ amount (match existing e (get amount e) u0)),
            contributed-at: stacks-block-height,
            refunded: false
          }
        )

        (map-set campaigns campaign-id (merge campaign {
          raised: (+ (get raised campaign) amount),
          contributor-count: (if (is-none existing)
            (+ (get contributor-count campaign) u1)
            (get contributor-count campaign)),
          status: (if (>= (+ (get raised campaign) amount) (get goal campaign)) u1 u0)
        }))

        (var-set total-raised (+ (var-get total-raised) amount))
        (ok { campaign-id: campaign-id, contributed: amount, total-raised: (+ (get raised campaign) amount) })
      )
    )
    err-not-found
  )
)

(define-public (claim-funds (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    campaign
    (let (
      (fee (get-platform-fee (get raised campaign)))
      (creator-amount (- (get raised campaign) fee))
    )
      (asserts! (is-eq tx-sender (get creator campaign)) err-not-authorized)
      (asserts! (>= (get raised campaign) (get goal campaign)) err-goal-not-met)
      (asserts! (not (get funds-claimed campaign)) err-already-claimed)
      (asserts! (> stacks-block-height (get end-block campaign)) err-campaign-closed)

      (try! (as-contract (stx-transfer? creator-amount tx-sender (get creator campaign))))
      (try! (as-contract (stx-transfer? fee tx-sender contract-owner)))

      (map-set campaigns campaign-id (merge campaign { funds-claimed: true }))
      (var-set platform-fees-collected (+ (var-get platform-fees-collected) fee))

      (ok { claimed: creator-amount, fee: fee })
    )
    err-not-found
  )
)

(define-public (claim-refund (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    campaign
    (match (map-get? contributions { campaign-id: campaign-id, contributor: tx-sender })
      contribution
      (begin
        (asserts! (< (get raised campaign) (get goal campaign)) err-goal-met)
        (asserts! (> stacks-block-height (get end-block campaign)) err-campaign-closed)
        (asserts! (not (get refunded contribution)) err-already-claimed)

        (try! (as-contract (stx-transfer? (get amount contribution) tx-sender tx-sender)))
        (map-set contributions
          { campaign-id: campaign-id, contributor: tx-sender }
          (merge contribution { refunded: true })
        )
        (ok { refunded: (get amount contribution) })
      )
      err-not-found
    )
    err-not-found
  )
)

(define-public (cancel-campaign (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    campaign
    (begin
      (asserts! (is-eq tx-sender (get creator campaign)) err-not-authorized)
      (asserts! (is-eq (get status campaign) u0) err-campaign-closed)
      (asserts! (is-eq (get raised campaign) u0) err-not-authorized)
      (map-set campaigns campaign-id (merge campaign { status: u3 }))
      (ok campaign-id)
    )
    err-not-found
  )
)
