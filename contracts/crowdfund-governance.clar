;; Crowdfund Governance Contract
;; Community governance for crowdfund platform decisions
;; Backers vote on platform parameters and featured campaigns

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u400))
(define-constant err-not-authorized (err u401))
(define-constant err-not-found (err u402))
(define-constant err-already-voted (err u403))
(define-constant err-voting-closed (err u404))
(define-constant err-invalid-type (err u405))

(define-constant MIN-VOTING-PERIOD u288)  ;; ~2 days
(define-constant QUORUM-BPS u1000)        ;; 10% quorum
(define-constant PASS-THRESHOLD-BPS u5100) ;; 51% to pass

(define-data-var proposal-count uint u0)
(define-data-var total-governance-power uint u0)

(define-map governance-members principal uint) ;; member -> voting power

;; Proposals
(define-map proposals uint
  {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 400),
    proposal-type: uint, ;; 1=fee-change, 2=feature-campaign, 3=blacklist, 4=general
    target: (optional principal),
    param-value: (optional uint),
    votes-for: uint,
    votes-against: uint,
    start-block: uint,
    end-block: uint,
    executed: bool,
    cancelled: bool
  }
)

(define-map votes { proposal-id: uint, voter: principal } { power: uint, support: bool, block: uint })

;; Featured campaigns (approved by governance)
(define-map featured-campaigns uint bool)

;; Read-only
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals proposal-id)
)

(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? votes { proposal-id: proposal-id, voter: voter })
)

(define-read-only (get-voting-power (member principal))
  (default-to u0 (map-get? governance-members member))
)

(define-read-only (is-featured (campaign-id uint))
  (default-to false (map-get? featured-campaigns campaign-id))
)

(define-read-only (has-quorum (proposal-id uint))
  (match (map-get? proposals proposal-id)
    p (> (/ (* (+ (get votes-for p) (get votes-against p)) u10000) (var-get total-governance-power)) QUORUM-BPS)
    false
  )
)

;; Public functions
(define-public (set-voting-power (member principal) (power uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (let ((old (get-voting-power member)))
      (map-set governance-members member power)
      (var-set total-governance-power (+ (- (var-get total-governance-power) old) power))
      (ok { member: member, power: power })
    )
  )
)

(define-public (create-proposal
    (title (string-ascii 100))
    (description (string-ascii 400))
    (proposal-type uint)
    (target (optional principal))
    (param-value (optional uint))
    (duration uint))
  (let ((proposal-id (var-get proposal-count)))
    (asserts! (> (get-voting-power tx-sender) u0) err-not-authorized)
    (asserts! (and (>= proposal-type u1) (<= proposal-type u4)) err-invalid-type)
    (asserts! (>= duration MIN-VOTING-PERIOD) err-invalid-type)

    (map-set proposals proposal-id {
      proposer: tx-sender,
      title: title,
      description: description,
      proposal-type: proposal-type,
      target: target,
      param-value: param-value,
      votes-for: u0,
      votes-against: u0,
      start-block: stacks-block-height,
      end-block: (+ stacks-block-height duration),
      executed: false,
      cancelled: false
    })

    (var-set proposal-count (+ proposal-id u1))
    (ok { proposal-id: proposal-id })
  )
)

(define-public (vote (proposal-id uint) (support bool))
  (match (map-get? proposals proposal-id)
    proposal
    (let ((power (get-voting-power tx-sender)))
      (asserts! (<= stacks-block-height (get end-block proposal)) err-voting-closed)
      (asserts! (not (get cancelled proposal)) err-voting-closed)
      (asserts! (> power u0) err-not-authorized)
      (asserts! (is-none (map-get? votes { proposal-id: proposal-id, voter: tx-sender })) err-already-voted)

      (map-set votes
        { proposal-id: proposal-id, voter: tx-sender }
        { power: power, support: support, block: stacks-block-height }
      )
      (map-set proposals proposal-id (merge proposal {
        votes-for: (if support (+ (get votes-for proposal) power) (get votes-for proposal)),
        votes-against: (if support (get votes-against proposal) (+ (get votes-against proposal) power))
      }))
      (ok { voted: support, power: power })
    )
    err-not-found
  )
)

(define-public (execute-proposal (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal
    (begin
      (asserts! (> stacks-block-height (get end-block proposal)) err-voting-closed)
      (asserts! (not (get executed proposal)) err-not-authorized)
      (asserts! (has-quorum proposal-id) err-not-authorized)
      (asserts! (> (get votes-for proposal) (get votes-against proposal)) err-not-authorized)

      ;; Execute based on type
      (if (is-eq (get proposal-type proposal) u2)
        (match (get target proposal)
          t (begin
              (map-set featured-campaigns (default-to u0 (get param-value proposal)) true)
              true)
          false
        )
        false
      )

      (map-set proposals proposal-id (merge proposal { executed: true }))
      (ok { proposal-id: proposal-id, executed: true })
    )
    err-not-found
  )
)
