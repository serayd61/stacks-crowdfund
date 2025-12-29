;; Stacks Crowdfunding
;; Decentralized fundraising platform on Stacks

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-campaign-owner (err u101))
(define-constant err-campaign-not-found (err u102))
(define-constant err-campaign-ended (err u103))
(define-constant err-campaign-active (err u104))
(define-constant err-goal-not-reached (err u105))
(define-constant err-already-claimed (err u106))
(define-constant err-no-contribution (err u107))
(define-constant err-invalid-amount (err u108))
(define-constant err-campaign-failed (err u109))

;; Platform fee: 2% (200 basis points)
(define-constant platform-fee u200)
(define-constant fee-denominator u10000)
(define-constant treasury 'SP2PEBKJ2W1ZDDF2QQ6Y4FXKZEDPT9J9R2NKD9WJB)

;; Data Variables
(define-data-var campaign-nonce uint u0)
(define-data-var total-raised uint u0)
(define-data-var total-campaigns uint u0)
(define-data-var successful-campaigns uint u0)

;; Campaign storage
(define-map campaigns uint
  {
    owner: principal,
    title: (string-utf8 128),
    description: (string-utf8 512),
    goal: uint,
    raised: uint,
    contributors-count: uint,
    start-block: uint,
    end-block: uint,
    claimed: bool,
    refunds-enabled: bool
  }
)

;; Contributions per campaign per user
(define-map contributions { campaign-id: uint, contributor: principal } uint)

;; Campaign milestones
(define-map milestones { campaign-id: uint, milestone-id: uint }
  {
    title: (string-utf8 128),
    amount: uint,
    completed: bool
  }
)

;; Creator stats
(define-map creator-stats principal
  {
    campaigns-created: uint,
    campaigns-successful: uint,
    total-raised: uint
  }
)

;; Backer stats
(define-map backer-stats principal
  {
    campaigns-backed: uint,
    total-contributed: uint
  }
)

;; Read-only functions
(define-read-only (get-campaign (campaign-id uint))
  (map-get? campaigns campaign-id)
)

(define-read-only (get-contribution (campaign-id uint) (contributor principal))
  (default-to u0 (map-get? contributions { campaign-id: campaign-id, contributor: contributor }))
)

(define-read-only (get-creator-stats (creator principal))
  (default-to 
    { campaigns-created: u0, campaigns-successful: u0, total-raised: u0 }
    (map-get? creator-stats creator)
  )
)

(define-read-only (get-backer-stats (backer principal))
  (default-to 
    { campaigns-backed: u0, total-contributed: u0 }
    (map-get? backer-stats backer)
  )
)

(define-read-only (get-platform-stats)
  {
    total-campaigns: (var-get total-campaigns),
    successful-campaigns: (var-get successful-campaigns),
    total-raised: (var-get total-raised)
  }
)

(define-read-only (is-campaign-active (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    campaign (and (<= stacks-block-height (get end-block campaign)) (not (get claimed campaign)))
    false
  )
)

(define-read-only (is-campaign-successful (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    campaign (>= (get raised campaign) (get goal campaign))
    false
  )
)

(define-read-only (calculate-fee (amount uint))
  (/ (* amount platform-fee) fee-denominator)
)

(define-read-only (get-progress-percentage (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    campaign 
    (if (> (get goal campaign) u0)
      (/ (* (get raised campaign) u100) (get goal campaign))
      u0
    )
    u0
  )
)

;; Public functions

;; Create a new campaign
(define-public (create-campaign (title (string-utf8 128)) (description (string-utf8 512)) (goal uint) (duration uint))
  (let (
    (campaign-id (var-get campaign-nonce))
  )
    (asserts! (> goal u0) err-invalid-amount)
    (asserts! (> duration u0) err-invalid-amount)
    
    ;; Create campaign
    (map-set campaigns campaign-id {
      owner: tx-sender,
      title: title,
      description: description,
      goal: goal,
      raised: u0,
      contributors-count: u0,
      start-block: stacks-block-height,
      end-block: (+ stacks-block-height duration),
      claimed: false,
      refunds-enabled: false
    })
    
    ;; Update stats
    (var-set campaign-nonce (+ campaign-id u1))
    (var-set total-campaigns (+ (var-get total-campaigns) u1))
    
    (let ((stats (get-creator-stats tx-sender)))
      (map-set creator-stats tx-sender 
        (merge stats { campaigns-created: (+ (get campaigns-created stats) u1) })
      )
    )
    
    (ok { campaign-id: campaign-id, end-block: (+ stacks-block-height duration) })
  )
)

;; Contribute to a campaign
(define-public (contribute (campaign-id uint) (amount uint))
  (match (map-get? campaigns campaign-id)
    campaign
    (let (
      (current-contribution (get-contribution campaign-id tx-sender))
      (is-new-contributor (is-eq current-contribution u0))
    )
      (asserts! (> amount u0) err-invalid-amount)
      (asserts! (<= stacks-block-height (get end-block campaign)) err-campaign-ended)
      (asserts! (not (get claimed campaign)) err-already-claimed)
      
      ;; Transfer funds
      (try! (stx-transfer? amount tx-sender treasury))
      
      ;; Update campaign
      (map-set campaigns campaign-id 
        (merge campaign {
          raised: (+ (get raised campaign) amount),
          contributors-count: (if is-new-contributor 
                               (+ (get contributors-count campaign) u1)
                               (get contributors-count campaign))
        })
      )
      
      ;; Update contribution
      (map-set contributions { campaign-id: campaign-id, contributor: tx-sender }
        (+ current-contribution amount)
      )
      
      ;; Update backer stats
      (let ((stats (get-backer-stats tx-sender)))
        (map-set backer-stats tx-sender 
          (merge stats {
            campaigns-backed: (if is-new-contributor 
                               (+ (get campaigns-backed stats) u1)
                               (get campaigns-backed stats)),
            total-contributed: (+ (get total-contributed stats) amount)
          })
        )
      )
      
      (ok { campaign-id: campaign-id, contributed: amount, total: (+ current-contribution amount) })
    )
    err-campaign-not-found
  )
)

;; Claim funds (campaign owner, only if successful)
(define-public (claim-funds (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    campaign
    (let (
      (raised (get raised campaign))
      (fee (calculate-fee raised))
      (owner-amount (- raised fee))
    )
      (asserts! (is-eq (get owner campaign) tx-sender) err-not-campaign-owner)
      (asserts! (> stacks-block-height (get end-block campaign)) err-campaign-active)
      (asserts! (>= raised (get goal campaign)) err-goal-not-reached)
      (asserts! (not (get claimed campaign)) err-already-claimed)
      
      ;; Mark as claimed
      (map-set campaigns campaign-id 
        (merge campaign { claimed: true })
      )
      
      ;; Update stats
      (var-set total-raised (+ (var-get total-raised) raised))
      (var-set successful-campaigns (+ (var-get successful-campaigns) u1))
      
      (let ((stats (get-creator-stats tx-sender)))
        (map-set creator-stats tx-sender 
          (merge stats {
            campaigns-successful: (+ (get campaigns-successful stats) u1),
            total-raised: (+ (get total-raised stats) raised)
          })
        )
      )
      
      (ok { campaign-id: campaign-id, claimed: owner-amount, fee: fee })
    )
    err-campaign-not-found
  )
)

;; Enable refunds (campaign owner, only if failed)
(define-public (enable-refunds (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    campaign
    (begin
      (asserts! (is-eq (get owner campaign) tx-sender) err-not-campaign-owner)
      (asserts! (> stacks-block-height (get end-block campaign)) err-campaign-active)
      (asserts! (< (get raised campaign) (get goal campaign)) err-goal-not-reached)
      (asserts! (not (get claimed campaign)) err-already-claimed)
      
      (map-set campaigns campaign-id 
        (merge campaign { refunds-enabled: true })
      )
      
      (ok { campaign-id: campaign-id, refunds-enabled: true })
    )
    err-campaign-not-found
  )
)

;; Claim refund (contributor, only if campaign failed and refunds enabled)
(define-public (claim-refund (campaign-id uint))
  (match (map-get? campaigns campaign-id)
    campaign
    (let (
      (contribution (get-contribution campaign-id tx-sender))
    )
      (asserts! (> contribution u0) err-no-contribution)
      (asserts! (> stacks-block-height (get end-block campaign)) err-campaign-active)
      (asserts! (< (get raised campaign) (get goal campaign)) err-campaign-failed)
      (asserts! (get refunds-enabled campaign) err-campaign-failed)
      
      ;; Clear contribution
      (map-set contributions { campaign-id: campaign-id, contributor: tx-sender } u0)
      
      ;; Update campaign raised amount
      (map-set campaigns campaign-id 
        (merge campaign {
          raised: (- (get raised campaign) contribution)
        })
      )
      
      (ok { campaign-id: campaign-id, refunded: contribution })
    )
    err-campaign-not-found
  )
)

;; Extend campaign deadline (owner only, before end)
(define-public (extend-deadline (campaign-id uint) (additional-blocks uint))
  (match (map-get? campaigns campaign-id)
    campaign
    (begin
      (asserts! (is-eq (get owner campaign) tx-sender) err-not-campaign-owner)
      (asserts! (<= stacks-block-height (get end-block campaign)) err-campaign-ended)
      
      (map-set campaigns campaign-id 
        (merge campaign {
          end-block: (+ (get end-block campaign) additional-blocks)
        })
      )
      
      (ok { campaign-id: campaign-id, new-end-block: (+ (get end-block campaign) additional-blocks) })
    )
    err-campaign-not-found
  )
)

;; Update campaign description
(define-public (update-description (campaign-id uint) (new-description (string-utf8 512)))
  (match (map-get? campaigns campaign-id)
    campaign
    (begin
      (asserts! (is-eq (get owner campaign) tx-sender) err-not-campaign-owner)
      
      (map-set campaigns campaign-id 
        (merge campaign { description: new-description })
      )
      
      (ok true)
    )
    err-campaign-not-found
  )
)

