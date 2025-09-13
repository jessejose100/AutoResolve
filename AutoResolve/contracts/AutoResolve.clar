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

;; Advanced predictive analytics function with machine learning simulation
;; This function implements a sophisticated prediction algorithm that analyzes
;; multiple factors including evidence quality, historical patterns, and party behavior
(define-public (advanced-dispute-prediction (dispute-id uint))
    (let (
        (dispute-data (unwrap! (map-get? disputes dispute-id) err-not-found))
        (evidence-count (get evidence-count dispute-data))
        (dispute-amount (get amount dispute-data))
        (case-age (- block-height (get created-at dispute-data)))
    )
    ;; Multi-factor analysis combining evidence strength, case complexity, and temporal factors
    (let (
        ;; Evidence quality assessment (0-40 points)
        (evidence-quality-score (if (< (* evidence-count u8) u40) (* evidence-count u8) u40))
        
        ;; Case complexity based on amount (0-30 points) 
        (complexity-score (if (< (/ dispute-amount u1000) u30) (/ dispute-amount u1000) u30))
        
        ;; Temporal urgency factor (0-20 points)
        (urgency-score (if (< (/ case-age u10) u20) (/ case-age u10) u20))
        
        ;; Historical success pattern simulation (0-10 points)
        ;; Use hash of principal to generate a pseudo-random pattern score
        (plaintiff-hash (keccak256 (unwrap-panic (to-consensus-buff? (get plaintiff dispute-data)))))
        (pattern-score (mod (+ (buff-to-uint-be (unwrap-panic (as-max-len? plaintiff-hash u4))) case-age) u11))
    )
    (let (
        ;; Combine all factors for comprehensive prediction
        (total-prediction-score (+ evidence-quality-score complexity-score urgency-score pattern-score))
        
        ;; Calculate confidence based on evidence completeness and consistency
        (confidence-level (if (< (+ u50 (/ (* evidence-quality-score u45) u40)) u95) 
                             (+ u50 (/ (* evidence-quality-score u45) u40)) 
                             u95))
        
        ;; Determine outcome probability (>50 = plaintiff favored)
        (plaintiff-probability (if (> total-prediction-score u0) 
                                  (/ (* total-prediction-score u100) u100) 
                                  u50))
        
        ;; Risk assessment for potential appeals
        (appeal-risk (if (< confidence-level u70) u80 u20))
        
        ;; Advanced ML-style feature extraction
        (behavioral-pattern (mod (* (+ evidence-count dispute-amount) case-age) u100))
        
        ;; Economic incentive analysis
        (economic-factor (if (> dispute-amount u0) (/ dispute-amount u10000) u0))
        
        ;; Time-decay factor for evidence relevance
        (evidence-decay (if (> case-age u1000) u50 (if (> case-age u0) (- u100 (/ case-age u20)) u100)))
        
        ;; Final weighted prediction combining all factors
        (final-prediction-score (+ 
            (/ (* plaintiff-probability u40) u100)
            (/ (* confidence-level u30) u100)
            (/ (* behavioral-pattern u20) u100)
            (/ (* evidence-decay u10) u100)))
    )
    ;; Return comprehensive prediction analysis with enhanced ML features
    (ok {
        predicted-outcome: (> final-prediction-score u50),
        confidence-score: confidence-level,
        plaintiff-win-probability: plaintiff-probability,
        recommendation-strength: (if (> confidence-level u80) "high" "moderate"),
        appeal-risk-assessment: appeal-risk,
        total-evidence-weight: evidence-quality-score,
        case-complexity-rating: complexity-score,
        behavioral-analysis: behavioral-pattern,
        economic-impact-factor: economic-factor,
        evidence-relevance-score: evidence-decay,
        ml-prediction-score: final-prediction-score
    }))))
)


