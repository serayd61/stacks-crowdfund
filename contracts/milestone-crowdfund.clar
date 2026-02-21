;; Milestone Crowdfund Contract
;; Funds released in tranches based on milestone completion
;; Protects backers from rug pulls via milestone voting

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-authorized (err u201))
(define-constant err-not-found (err u202))
(define-constant err-not-active (err u203))
(define-constant err-already-voted (err u204))
(define-constant err-milestone-not-ready (err u205))
(define-constant err-invalid-amount (err u206))

(define-constant APPROVAL-THRESHOLD-BPS u5000) ;; 50% approval needed
(define-constant VOTING-PERIOD u288)            ;; ~2 days

(define-data-var project-count uint u0)
(define-data-var milestone-count uint u0)

;; Projects
(define-map projects uint
  {
    creator: principal,
    title: (string-ascii 100),
    total-goal: uint,
    total-raised: uint,
    milestones-count: uint,
    milestones-completed: uint,
    status: uint,  ;; 0=fundraising, 1=active, 2=completed, 3=failed
    created-at: uint,
    end-fundraise: uint
  }
)

;; Milestones
(define-map milestones
  { project-id: uint, milestone-index: uint }
  {
    title: (string-ascii 100),
    description: (string-ascii 300),
    amount: uint,
    deadline: uint,
    status: uint,  ;; 0=locked, 1=voting, 2=approved, 3=rejected, 4=paid
    votes-approve: uint,
    votes-reject: uint,
    voting-started: uint,
    proof-url: (string-ascii 200)
  }
)

;; Backer records
(define-map backers
  { project-id: uint, backer: principal }
  { amount: uint, voting-power: uint, backed-at: uint, refunded: bool }
)

;; Milestone votes
(define-map milestone-votes
  { project-id: uint, milestone-index: uint, voter: principal }
  uint  ;; 0=reject, 1=approve
)

;; Read-only
(define-read-only (get-project (project-id uint))
  (map-get? projects project-id)
)

(define-read-only (get-milestone (project-id uint) (milestone-index uint))
  (map-get? milestones { project-id: project-id, milestone-index: milestone-index })
)

(define-read-only (get-backer (project-id uint) (backer principal))
  (map-get? backers { project-id: project-id, backer: backer })
)

(define-read-only (has-voted-milestone (project-id uint) (milestone-index uint) (voter principal))
  (is-some (map-get? milestone-votes { project-id: project-id, milestone-index: milestone-index, voter: voter }))
)

;; Public functions
(define-public (create-project
    (title (string-ascii 100))
    (total-goal uint)
    (fundraise-duration uint))
  (let ((project-id (var-get project-count)))
    (asserts! (> total-goal u0) err-invalid-amount)
    (map-set projects project-id {
      creator: tx-sender,
      title: title,
      total-goal: total-goal,
      total-raised: u0,
      milestones-count: u0,
      milestones-completed: u0,
      status: u0,
      created-at: stacks-block-height,
      end-fundraise: (+ stacks-block-height fundraise-duration)
    })
    (var-set project-count (+ project-id u1))
    (ok { project-id: project-id })
  )
)

(define-public (add-milestone
    (project-id uint)
    (title (string-ascii 100))
    (description (string-ascii 300))
    (amount uint)
    (deadline uint))
  (match (map-get? projects project-id)
    project
    (let ((milestone-index (get milestones-count project)))
      (asserts! (is-eq tx-sender (get creator project)) err-not-authorized)
      (asserts! (is-eq (get status project) u0) err-not-active)

      (map-set milestones
        { project-id: project-id, milestone-index: milestone-index }
        {
          title: title,
          description: description,
          amount: amount,
          deadline: deadline,
          status: u0,
          votes-approve: u0,
          votes-reject: u0,
          voting-started: u0,
          proof-url: ""
        }
      )

      (map-set projects project-id (merge project {
        milestones-count: (+ milestone-index u1)
      }))

      (ok { project-id: project-id, milestone-index: milestone-index })
    )
    err-not-found
  )
)

(define-public (back-project (project-id uint) (amount uint))
  (match (map-get? projects project-id)
    project
    (begin
      (asserts! (is-eq (get status project) u0) err-not-active)
      (asserts! (<= stacks-block-height (get end-fundraise project)) err-not-active)
      (asserts! (> amount u0) err-invalid-amount)

      (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))

      (let ((existing (map-get? backers { project-id: project-id, backer: tx-sender })))
        (map-set backers
          { project-id: project-id, backer: tx-sender }
          {
            amount: (+ amount (match existing e (get amount e) u0)),
            voting-power: (+ amount (match existing e (get amount e) u0)),
            backed-at: stacks-block-height,
            refunded: false
          }
        )
        (map-set projects project-id (merge project {
          total-raised: (+ (get total-raised project) amount),
          status: (if (>= (+ (get total-raised project) amount) (get total-goal project)) u1 u0)
        }))
      )
      (ok { backed: amount })
    )
    err-not-found
  )
)

(define-public (submit-milestone-proof
    (project-id uint)
    (milestone-index uint)
    (proof-url (string-ascii 200)))
  (match (map-get? milestones { project-id: project-id, milestone-index: milestone-index })
    milestone
    (begin
      (asserts! (is-eq tx-sender (unwrap! (get creator (map-get? projects project-id)) err-not-found)) err-not-authorized)
      (asserts! (is-eq (get status milestone) u0) err-not-active)
      (map-set milestones
        { project-id: project-id, milestone-index: milestone-index }
        (merge milestone { status: u1, voting-started: stacks-block-height, proof-url: proof-url })
      )
      (ok { project-id: project-id, milestone-index: milestone-index, voting-ends: (+ stacks-block-height VOTING-PERIOD) })
    )
    err-not-found
  )
)

(define-public (vote-milestone
    (project-id uint)
    (milestone-index uint)
    (approve bool))
  (match (map-get? milestones { project-id: project-id, milestone-index: milestone-index })
    milestone
    (match (map-get? backers { project-id: project-id, backer: tx-sender })
      backer
      (begin
        (asserts! (is-eq (get status milestone) u1) err-milestone-not-ready)
        (asserts! (<= stacks-block-height (+ (get voting-started milestone) VOTING-PERIOD)) err-not-active)
        (asserts! (not (has-voted-milestone project-id milestone-index tx-sender)) err-already-voted)

        (map-set milestone-votes
          { project-id: project-id, milestone-index: milestone-index, voter: tx-sender }
          (if approve u1 u0)
        )

        (map-set milestones
          { project-id: project-id, milestone-index: milestone-index }
          (merge milestone {
            votes-approve: (if approve (+ (get votes-approve milestone) (get voting-power backer)) (get votes-approve milestone)),
            votes-reject: (if approve (get votes-reject milestone) (+ (get votes-reject milestone) (get voting-power backer)))
          })
        )
        (ok { voted: approve })
      )
      err-not-found
    )
    err-not-found
  )
)

(define-public (finalize-milestone (project-id uint) (milestone-index uint))
  (match (map-get? milestones { project-id: project-id, milestone-index: milestone-index })
    milestone
    (match (map-get? projects project-id)
      project
      (begin
        (asserts! (is-eq (get status milestone) u1) err-milestone-not-ready)
        (asserts! (> stacks-block-height (+ (get voting-started milestone) VOTING-PERIOD)) err-not-active)

        (let (
          (total-votes (+ (get votes-approve milestone) (get votes-reject milestone)))
          (approved (>= (/ (* (get votes-approve milestone) u10000) (if (> total-votes u0) total-votes u1)) APPROVAL-THRESHOLD-BPS))
        )
          (if approved
            (begin
              (try! (as-contract (stx-transfer? (get amount milestone) tx-sender (get creator project))))
              (map-set milestones { project-id: project-id, milestone-index: milestone-index }
                (merge milestone { status: u4 }))
              (map-set projects project-id (merge project {
                milestones-completed: (+ (get milestones-completed project) u1)
              }))
              (ok { approved: true, paid: (get amount milestone) })
            )
            (begin
              (map-set milestones { project-id: project-id, milestone-index: milestone-index }
                (merge milestone { status: u3 }))
              (ok { approved: false, paid: u0 })
            )
          )
        )
      )
      err-not-found
    )
    err-not-found
  )
)
