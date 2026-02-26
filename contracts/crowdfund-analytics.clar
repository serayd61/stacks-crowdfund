;; Crowdfund Analytics Contract
;; On-chain analytics for crowdfund platform
;; Tracks campaigns, success rates, and backer stats

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u500))
(define-constant err-not-authorized (err u501))

(define-data-var total-campaigns uint u0)
(define-data-var successful-campaigns uint u0)
(define-data-var failed-campaigns uint u0)
(define-data-var total-raised uint u0)
(define-data-var total-backers uint u0)
(define-data-var total-contributions uint u0)

(define-map authorized-reporters principal bool)

;; Category stats
(define-map category-stats (string-ascii 30)
  {
    campaign-count: uint,
    successful: uint,
    total-raised: uint,
    avg-goal: uint
  }
)

;; Monthly stats
(define-map monthly-stats uint
  {
    month-block: uint,
    new-campaigns: uint,
    successful: uint,
    total-raised: uint,
    new-backers: uint,
    avg-contribution: uint
  }
)

(define-data-var month-count uint u0)

;; Backer stats
(define-map backer-stats principal
  {
    campaigns-backed: uint,
    total-contributed: uint,
    successful-exits: uint,
    refunds-received: uint,
    first-backed: uint,
    last-backed: uint
  }
)

;; Read-only
(define-read-only (get-platform-stats)
  {
    total-campaigns: (var-get total-campaigns),
    successful: (var-get successful-campaigns),
    failed: (var-get failed-campaigns),
    total-raised: (var-get total-raised),
    total-backers: (var-get total-backers),
    success-rate-bps: (if (> (var-get total-campaigns) u0)
      (/ (* (var-get successful-campaigns) u10000) (var-get total-campaigns))
      u0)
  }
)

(define-read-only (get-category-stats (category (string-ascii 30)))
  (map-get? category-stats category)
)

(define-read-only (get-backer-stats (backer principal))
  (map-get? backer-stats backer)
)

(define-read-only (get-monthly-stats (month-id uint))
  (map-get? monthly-stats month-id)
)

(define-read-only (is-reporter (r principal))
  (default-to false (map-get? authorized-reporters r))
)

;; Public functions
(define-public (add-reporter (reporter principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-reporters reporter true)
    (ok reporter)
  )
)

(define-public (record-campaign-created (category (string-ascii 30)) (goal uint))
  (begin
    (asserts! (is-reporter tx-sender) err-not-authorized)
    (var-set total-campaigns (+ (var-get total-campaigns) u1))

    (match (map-get? category-stats category)
      stats
      (map-set category-stats category (merge stats {
        campaign-count: (+ (get campaign-count stats) u1),
        avg-goal: (/ (+ (* (get avg-goal stats) (get campaign-count stats)) goal) (+ (get campaign-count stats) u1))
      }))
      (map-set category-stats category {
        campaign-count: u1, successful: u0, total-raised: u0, avg-goal: goal
      })
    )
    (ok { total: (var-get total-campaigns) })
  )
)

(define-public (record-campaign-result
    (category (string-ascii 30))
    (raised uint)
    (succeeded bool)
    (backer-count uint))
  (begin
    (asserts! (is-reporter tx-sender) err-not-authorized)

    (if succeeded
      (var-set successful-campaigns (+ (var-get successful-campaigns) u1))
      (var-set failed-campaigns (+ (var-get failed-campaigns) u1))
    )

    (var-set total-raised (+ (var-get total-raised) raised))

    (match (map-get? category-stats category)
      stats
      (map-set category-stats category (merge stats {
        successful: (if succeeded (+ (get successful stats) u1) (get successful stats)),
        total-raised: (+ (get total-raised stats) raised)
      }))
      false
    )
    (ok { succeeded: succeeded, raised: raised })
  )
)

(define-public (record-contribution (backer principal) (amount uint) (is-new-backer bool))
  (begin
    (asserts! (is-reporter tx-sender) err-not-authorized)

    (if is-new-backer (var-set total-backers (+ (var-get total-backers) u1)) false)
    (var-set total-contributions (+ (var-get total-contributions) amount))

    (match (map-get? backer-stats backer)
      stats
      (map-set backer-stats backer (merge stats {
        campaigns-backed: (+ (get campaigns-backed stats) u1),
        total-contributed: (+ (get total-contributed stats) amount),
        last-backed: stacks-block-height
      }))
      (map-set backer-stats backer {
        campaigns-backed: u1,
        total-contributed: amount,
        successful-exits: u0,
        refunds-received: u0,
        first-backed: stacks-block-height,
        last-backed: stacks-block-height
      })
    )
    (ok { backer: backer, amount: amount })
  )
)

(define-public (record-monthly-snapshot
    (new-campaigns uint)
    (successful uint)
    (raised uint)
    (new-backers uint)
    (avg-contribution uint))
  (let ((month-id (var-get month-count)))
    (asserts! (is-reporter tx-sender) err-not-authorized)
    (map-set monthly-stats month-id {
      month-block: stacks-block-height,
      new-campaigns: new-campaigns,
      successful: successful,
      total-raised: raised,
      new-backers: new-backers,
      avg-contribution: avg-contribution
    })
    (var-set month-count (+ month-id u1))
    (ok month-id)
  )
)
