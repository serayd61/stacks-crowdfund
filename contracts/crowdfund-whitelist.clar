;; Crowdfund Whitelist Contract
;; KYC/AML compliance layer for crowdfund platform
;; Manages verified creators and backers

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u600))
(define-constant err-not-authorized (err u601))
(define-constant err-not-found (err u602))
(define-constant err-already-verified (err u603))
(define-constant err-blacklisted (err u604))
(define-constant err-not-verified (err u605))

(define-constant VERIFICATION-EXPIRY u52596) ;; ~1 year in blocks

(define-data-var verifier-count uint u0)
(define-data-var verified-creators uint u0)
(define-data-var verified-backers uint u0)

(define-map verifiers principal bool)

;; Verified creators
(define-map verified-creator-list principal
  {
    verified-at: uint,
    verified-by: principal,
    expiry: uint,
    tier: uint,           ;; 1=standard, 2=premium, 3=enterprise
    max-campaign-goal: uint,
    campaigns-created: uint,
    active: bool
  }
)

;; Verified backers
(define-map verified-backer-list principal
  {
    verified-at: uint,
    verified-by: principal,
    expiry: uint,
    max-contribution: uint,
    total-contributed: uint,
    active: bool
  }
)

;; Blacklist
(define-map blacklist principal { reason: (string-ascii 100), added-at: uint, added-by: principal })

;; Read-only
(define-read-only (is-verified-creator (creator principal))
  (match (map-get? verified-creator-list creator)
    v (and (get active v) (<= stacks-block-height (get expiry v)))
    false
  )
)

(define-read-only (is-verified-backer (backer principal))
  (match (map-get? verified-backer-list backer)
    v (and (get active v) (<= stacks-block-height (get expiry v)))
    false
  )
)

(define-read-only (is-blacklisted (account principal))
  (is-some (map-get? blacklist account))
)

(define-read-only (get-creator-info (creator principal))
  (map-get? verified-creator-list creator)
)

(define-read-only (get-backer-info (backer principal))
  (map-get? verified-backer-list backer)
)

(define-read-only (is-verifier (v principal))
  (default-to false (map-get? verifiers v))
)

;; Public functions
(define-public (add-verifier (verifier principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set verifiers verifier true)
    (var-set verifier-count (+ (var-get verifier-count) u1))
    (ok verifier)
  )
)

(define-public (verify-creator (creator principal) (tier uint) (max-goal uint))
  (begin
    (asserts! (is-verifier tx-sender) err-not-authorized)
    (asserts! (not (is-blacklisted creator)) err-blacklisted)
    (asserts! (and (>= tier u1) (<= tier u3)) err-not-authorized)

    (map-set verified-creator-list creator {
      verified-at: stacks-block-height,
      verified-by: tx-sender,
      expiry: (+ stacks-block-height VERIFICATION-EXPIRY),
      tier: tier,
      max-campaign-goal: max-goal,
      campaigns-created: u0,
      active: true
    })

    (var-set verified-creators (+ (var-get verified-creators) u1))
    (ok { creator: creator, tier: tier, max-goal: max-goal })
  )
)

(define-public (verify-backer (backer principal) (max-contribution uint))
  (begin
    (asserts! (is-verifier tx-sender) err-not-authorized)
    (asserts! (not (is-blacklisted backer)) err-blacklisted)

    (map-set verified-backer-list backer {
      verified-at: stacks-block-height,
      verified-by: tx-sender,
      expiry: (+ stacks-block-height VERIFICATION-EXPIRY),
      max-contribution: max-contribution,
      total-contributed: u0,
      active: true
    })

    (var-set verified-backers (+ (var-get verified-backers) u1))
    (ok { backer: backer, max-contribution: max-contribution })
  )
)

(define-public (revoke-creator (creator principal))
  (match (map-get? verified-creator-list creator)
    v
    (begin
      (asserts! (is-verifier tx-sender) err-not-authorized)
      (map-set verified-creator-list creator (merge v { active: false }))
      (ok creator)
    )
    err-not-found
  )
)

(define-public (blacklist-account (account principal) (reason (string-ascii 100)))
  (begin
    (asserts! (is-verifier tx-sender) err-not-authorized)
    (map-set blacklist account { reason: reason, added-at: stacks-block-height, added-by: tx-sender })
    (ok account)
  )
)

(define-public (remove-from-blacklist (account principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-delete blacklist account)
    (ok account)
  )
)
