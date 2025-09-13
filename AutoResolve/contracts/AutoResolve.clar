;; Automated Dispute Resolution with Predictive Analytics
;; This contract enables automated dispute resolution using predictive analytics to assess
;; dispute outcomes and facilitate fair resolutions between parties. It includes escrow
;; functionality, evidence submission, and ML-based outcome prediction.

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-unauthorized (err u102))
(define-constant err-invalid-state (err u103))
(define-constant err-insufficient-funds (err u104))
(define-constant err-invalid-evidence (err u105))

;; Dispute states
(define-constant dispute-state-open u1)
(define-constant dispute-state-evidence u2)
(define-constant dispute-state-resolved u3)
(define-constant dispute-state-appealed u4)

;; data maps and vars
;; Global dispute counter
(define-data-var dispute-counter uint u0)

;; Dispute details storage
(define-map disputes uint {
    plaintiff: principal,
    defendant: principal,
    amount: uint,
    state: uint,
    created-at: uint,
    resolved-at: (optional uint),
    outcome: (optional bool), ;; true = plaintiff wins, false = defendant wins
    confidence-score: (optional uint), ;; 0-100 prediction confidence
    evidence-count: uint,
    appeal-deadline: (optional uint)
})

;; Evidence submissions
(define-map evidence {dispute-id: uint, evidence-id: uint} {
    submitter: principal,
    evidence-hash: (buff 32),
    weight: uint, ;; 1-10 evidence importance weight
    timestamp: uint
})

;; Evidence counter per dispute
(define-map evidence-counters uint uint)

;; Escrow holdings
(define-map escrow uint uint)

;; Predictive model weights for different evidence types
(define-map model-weights (buff 4) uint)

;; Arbitrator registry
(define-map arbitrators principal bool)

;; private functions
;; Calculate dispute outcome using predictive analytics
(define-private (calculate-prediction (dispute-id uint))
    (let (
        (dispute-data (unwrap! (map-get? disputes dispute-id) (err err-not-found)))
        (evidence-count (get evidence-count dispute-data))
    )
    (if (> evidence-count u0)
        (let (
            (plaintiff-score (calculate-evidence-score dispute-id (get plaintiff dispute-data)))
            (defendant-score (calculate-evidence-score dispute-id (get defendant dispute-data)))
            (total-score (+ plaintiff-score defendant-score))
        )
        (if (> total-score u0)
            (ok {
                outcome: (> plaintiff-score defendant-score),
                confidence: (/ (* (if (> plaintiff-score defendant-score) plaintiff-score defendant-score) u100) total-score)
            })
            (ok {outcome: true, confidence: u50}) ;; Default if no evidence weighted
        ))
        (ok {outcome: true, confidence: u50}) ;; Default prediction
    )))

;; Calculate evidence score for a party
(define-private (calculate-evidence-score (dispute-id uint) (party principal))
    (fold + (map get-evidence-weight (enumerate-evidence dispute-id party)) u0)
)

;; Get evidence weight (simplified - in real implementation would analyze evidence)
(define-private (get-evidence-weight (evidence-data {dispute-id: uint, evidence-id: uint}))
    (default-to u5 (get weight (map-get? evidence evidence-data)))
)

;; Enumerate evidence for a party (simplified)
(define-private (enumerate-evidence (dispute-id uint) (party principal))
    (list {dispute-id: dispute-id, evidence-id: u1})
)

;; Release escrowed funds
(define-private (release-escrow (dispute-id uint) (winner principal))
    (let (
        (amount (default-to u0 (map-get? escrow dispute-id)))
    )
    (map-delete escrow dispute-id)
    (as-contract (stx-transfer? amount tx-sender winner)))
)

;; public functions
;; Create a new dispute with escrow
(define-public (create-dispute (defendant principal) (amount uint))
    (let (
        (dispute-id (+ (var-get dispute-counter) u1))
        (current-height block-height)
    )
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set disputes dispute-id {
        plaintiff: tx-sender,
        defendant: defendant,
        amount: amount,
        state: dispute-state-open,
        created-at: current-height,
        resolved-at: none,
        outcome: none,
        confidence-score: none,
        evidence-count: u0,
        appeal-deadline: none
    })
    (map-set escrow dispute-id amount)
    (map-set evidence-counters dispute-id u0)
    (var-set dispute-counter dispute-id)
    (ok dispute-id))
)

;; Submit evidence for a dispute
(define-public (submit-evidence (dispute-id uint) (evidence-hash (buff 32)) (weight uint))
    (let (
        (dispute-data (unwrap! (map-get? disputes dispute-id) err-not-found))
        (evidence-count (default-to u0 (map-get? evidence-counters dispute-id)))
        (new-evidence-id (+ evidence-count u1))
    )
    (asserts! (or (is-eq tx-sender (get plaintiff dispute-data)) 
                  (is-eq tx-sender (get defendant dispute-data))) err-unauthorized)
    (asserts! (is-eq (get state dispute-data) dispute-state-evidence) err-invalid-state)
    (asserts! (and (>= weight u1) (<= weight u10)) err-invalid-evidence)
    
    (map-set evidence {dispute-id: dispute-id, evidence-id: new-evidence-id} {
        submitter: tx-sender,
        evidence-hash: evidence-hash,
        weight: weight,
        timestamp: block-height
    })
    (map-set evidence-counters dispute-id new-evidence-id)
    (map-set disputes dispute-id (merge dispute-data {evidence-count: new-evidence-id}))
    (ok new-evidence-id))
)

;; Transition dispute to evidence phase
(define-public (open-evidence-phase (dispute-id uint))
    (let (
        (dispute-data (unwrap! (map-get? disputes dispute-id) err-not-found))
    )
    (asserts! (or (is-eq tx-sender (get plaintiff dispute-data))
                  (is-eq tx-sender (get defendant dispute-data))) err-unauthorized)
    (asserts! (is-eq (get state dispute-data) dispute-state-open) err-invalid-state)
    
    (map-set disputes dispute-id (merge dispute-data {state: dispute-state-evidence}))
    (ok true))
)

;; Resolve dispute using predictive analytics
(define-public (resolve-dispute (dispute-id uint))
    (let (
        (dispute-data (unwrap! (map-get? disputes dispute-id) err-not-found))
        (prediction (unwrap! (calculate-prediction dispute-id) (err u999)))
    )
    (asserts! (is-eq (get state dispute-data) dispute-state-evidence) err-invalid-state)
    (asserts! (default-to false (map-get? arbitrators tx-sender)) err-unauthorized)
    
    (let (
        (winner (if (get outcome prediction) (get plaintiff dispute-data) (get defendant dispute-data)))
        (current-height block-height)
    )
    (try! (release-escrow dispute-id winner))
    (map-set disputes dispute-id (merge dispute-data {
        state: dispute-state-resolved,
        resolved-at: (some current-height),
        outcome: (some (get outcome prediction)),
        confidence-score: (some (get confidence prediction)),
        appeal-deadline: (some (+ current-height u144)) ;; 24 hours in blocks
    }))
    (ok {winner: winner, confidence: (get confidence prediction)})))
)

;; Register arbitrator (only contract owner)
(define-public (register-arbitrator (arbitrator principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (map-set arbitrators arbitrator true)
        (ok true))
)


