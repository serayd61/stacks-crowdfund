;; Crowdfund Referral Contract
;; Referral and affiliate program for crowdfund platform
;; Rewards users who bring backers to campaigns

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u800))
(define-constant err-not-authorized (err u801))
(define-constant err-not-found (err u802))
(define-constant err-self-referral (err u803))
(define-constant err-already-referred (err u804))
(define-constant err-invalid-rate (err u805))

(define-constant DEFAULT-REFERRAL-RATE-BPS u100) ;; 1% of contribution
(define-constant MAX-REFERRAL-RATE-BPS u500)     ;; 5% max
(define-constant MIN-CONTRIBUTION-FOR-REWARD u1000000)

(define-data-var referral-count uint u0)
(define-data-var total-referral-rewards uint u0)
(define-data-var program-active bool true)

;; Referral codes
(define-map referral-codes (string-ascii 20) principal)
(define-map user-referral-code principal (string-ascii 20))

;; Referral tracking
(define-map referrals uint
  {
    referrer: principal,
    referred: principal,
    campaign-id: uint,
    contribution: uint,
    reward: uint,
    created-at: uint,
    paid: bool
  }
)

(define-map referrer-stats principal
  {
    total-referrals: uint,
    total-contributions-referred: uint,
    total-rewards-earned: uint,
    total-rewards-paid: uint,
    active: bool
  }
)

;; Campaign-specific referral rates
(define-map campaign-referral-rate uint uint) ;; campaign-id -> rate bps

;; Read-only
(define-read-only (get-referral-code (user principal))
  (map-get? user-referral-code user)
)

(define-read-only (get-code-owner (code (string-ascii 20)))
  (map-get? referral-codes code)
)

(define-read-only (get-referrer-stats (referrer principal))
  (map-get? referrer-stats referrer)
)

(define-read-only (get-referral (referral-id uint))
  (map-get? referrals referral-id)
)

(define-read-only (get-campaign-rate (campaign-id uint))
  (default-to DEFAULT-REFERRAL-RATE-BPS (map-get? campaign-referral-rate campaign-id))
)

(define-read-only (calculate-referral-reward (campaign-id uint) (contribution uint))
  (/ (* contribution (get-campaign-rate campaign-id)) u10000)
)

;; Public functions
(define-public (create-referral-code (code (string-ascii 20)))
  (begin
    (asserts! (var-get program-active) err-not-authorized)
    (asserts! (is-none (map-get? referral-codes code)) err-already-referred)
    (asserts! (is-none (map-get? user-referral-code tx-sender)) err-already-referred)

    (map-set referral-codes code tx-sender)
    (map-set user-referral-code tx-sender code)

    ;; Init stats
    (map-set referrer-stats tx-sender {
      total-referrals: u0,
      total-contributions-referred: u0,
      total-rewards-earned: u0,
      total-rewards-paid: u0,
      active: true
    })

    (ok { code: code, referrer: tx-sender })
  )
)

(define-public (record-referral
    (referral-code (string-ascii 20))
    (referred principal)
    (campaign-id uint)
    (contribution uint))
  (match (map-get? referral-codes referral-code)
    referrer
    (let (
      (referral-id (var-get referral-count))
      (reward (calculate-referral-reward campaign-id contribution))
    )
      (asserts! (is-eq tx-sender contract-owner) err-owner-only)
      (asserts! (not (is-eq referrer referred)) err-self-referral)
      (asserts! (>= contribution MIN-CONTRIBUTION-FOR-REWARD) err-invalid-rate)

      (map-set referrals referral-id {
        referrer: referrer,
        referred: referred,
        campaign-id: campaign-id,
        contribution: contribution,
        reward: reward,
        created-at: stacks-block-height,
        paid: false
      })

      (match (map-get? referrer-stats referrer)
        stats
        (map-set referrer-stats referrer (merge stats {
          total-referrals: (+ (get total-referrals stats) u1),
          total-contributions-referred: (+ (get total-contributions-referred stats) contribution),
          total-rewards-earned: (+ (get total-rewards-earned stats) reward)
        }))
        false
      )

      (var-set referral-count (+ referral-id u1))
      (var-set total-referral-rewards (+ (var-get total-referral-rewards) reward))

      (ok { referral-id: referral-id, reward: reward })
    )
    err-not-found
  )
)

(define-public (pay-referral-reward (referral-id uint))
  (match (map-get? referrals referral-id)
    referral
    (begin
      (asserts! (is-eq tx-sender contract-owner) err-owner-only)
      (asserts! (not (get paid referral)) err-not-authorized)
      (asserts! (> (get reward referral) u0) err-invalid-rate)

      (try! (as-contract (stx-transfer? (get reward referral) tx-sender (get referrer referral))))

      (map-set referrals referral-id (merge referral { paid: true }))

      (match (map-get? referrer-stats (get referrer referral))
        stats
        (map-set referrer-stats (get referrer referral) (merge stats {
          total-rewards-paid: (+ (get total-rewards-paid stats) (get reward referral))
        }))
        false
      )

      (ok { paid: (get reward referral), referrer: (get referrer referral) })
    )
    err-not-found
  )
)

(define-public (set-campaign-rate (campaign-id uint) (rate-bps uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= rate-bps MAX-REFERRAL-RATE-BPS) err-invalid-rate)
    (map-set campaign-referral-rate campaign-id rate-bps)
    (ok { campaign-id: campaign-id, rate-bps: rate-bps })
  )
)

(define-public (toggle-program (active bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set program-active active)
    (ok active)
  )
)
