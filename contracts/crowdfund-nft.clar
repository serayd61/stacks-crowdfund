;; Crowdfund NFT Reward Contract
;; Backers receive NFT rewards based on contribution tiers
;; SIP-009 style NFT for crowdfund participants

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u300))
(define-constant err-not-authorized (err u301))
(define-constant err-not-found (err u302))
(define-constant err-already-minted (err u303))
(define-constant err-invalid-tier (err u304))

(define-constant TIER-BRONZE-MIN u1000000)     ;; 1 STX
(define-constant TIER-SILVER-MIN u10000000)    ;; 10 STX
(define-constant TIER-GOLD-MIN u100000000)     ;; 100 STX
(define-constant TIER-DIAMOND-MIN u1000000000) ;; 1000 STX

(define-data-var token-id-nonce uint u0)
(define-data-var total-minted uint u0)

(define-map authorized-minters principal bool)

;; NFT ownership
(define-map nft-owners uint principal)
(define-map owner-tokens principal (list 20 uint))

;; NFT metadata
(define-map nft-metadata uint
  {
    campaign-id: uint,
    backer: principal,
    tier: uint,         ;; 1=bronze, 2=silver, 3=gold, 4=diamond
    contribution: uint,
    minted-at: uint,
    transferable: bool
  }
)

;; Prevent double-mint per campaign
(define-map campaign-minted
  { campaign-id: uint, backer: principal }
  uint  ;; token-id
)

;; Read-only
(define-read-only (get-owner (token-id uint))
  (map-get? nft-owners token-id)
)

(define-read-only (get-metadata (token-id uint))
  (map-get? nft-metadata token-id)
)

(define-read-only (get-tier-for-contribution (amount uint))
  (if (>= amount TIER-DIAMOND-MIN) u4
    (if (>= amount TIER-GOLD-MIN) u3
      (if (>= amount TIER-SILVER-MIN) u2 u1)
    )
  )
)

(define-read-only (get-tier-label (tier uint))
  (if (is-eq tier u4) "DIAMOND"
    (if (is-eq tier u3) "GOLD"
      (if (is-eq tier u2) "SILVER" "BRONZE")))
)

(define-read-only (has-nft (campaign-id uint) (backer principal))
  (is-some (map-get? campaign-minted { campaign-id: campaign-id, backer: backer }))
)

(define-read-only (get-tokens-for-owner (owner principal))
  (default-to (list) (map-get? owner-tokens owner))
)

(define-read-only (get-token-count)
  (var-get total-minted)
)

;; Public functions
(define-public (add-minter (minter principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-minters minter true)
    (ok minter)
  )
)

(define-public (mint-reward
    (campaign-id uint)
    (backer principal)
    (contribution uint))
  (let (
    (token-id (var-get token-id-nonce))
    (tier (get-tier-for-contribution contribution))
  )
    (asserts! (or (is-eq tx-sender contract-owner)
                  (default-to false (map-get? authorized-minters tx-sender))) err-not-authorized)
    (asserts! (not (has-nft campaign-id backer)) err-already-minted)
    (asserts! (>= contribution TIER-BRONZE-MIN) err-invalid-tier)

    (map-set nft-owners token-id backer)
    (map-set nft-metadata token-id {
      campaign-id: campaign-id,
      backer: backer,
      tier: tier,
      contribution: contribution,
      minted-at: stacks-block-height,
      transferable: true
    })

    (map-set campaign-minted { campaign-id: campaign-id, backer: backer } token-id)

    (let ((current-tokens (get-tokens-for-owner backer)))
      (map-set owner-tokens backer (unwrap-panic (as-max-len? (append current-tokens token-id) u20)))
    )

    (var-set token-id-nonce (+ token-id u1))
    (var-set total-minted (+ (var-get total-minted) u1))

    (ok { token-id: token-id, tier: (get-tier-label tier), backer: backer })
  )
)

(define-public (transfer-nft (token-id uint) (recipient principal))
  (match (map-get? nft-metadata token-id)
    metadata
    (begin
      (asserts! (is-eq (some tx-sender) (map-get? nft-owners token-id)) err-not-authorized)
      (asserts! (get transferable metadata) err-not-authorized)
      (map-set nft-owners token-id recipient)
      (ok { token-id: token-id, new-owner: recipient })
    )
    err-not-found
  )
)

(define-public (lock-nft (token-id uint))
  (match (map-get? nft-metadata token-id)
    metadata
    (begin
      (asserts! (is-eq (some tx-sender) (map-get? nft-owners token-id)) err-not-authorized)
      (map-set nft-metadata token-id (merge metadata { transferable: false }))
      (ok token-id)
    )
    err-not-found
  )
)
