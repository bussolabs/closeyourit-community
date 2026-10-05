# frozen_string_literal: true

# CYAU-176 — le impronte di ciò che il reviewer ha REALMENTE letto, che una consegna con profondità "diff"
# deve portare. Stanno qui e non copiate in ogni spec perché le tre lunghezze non sono uguali e sbagliarle
# in un solo file produrrebbe un rosso che sembra del codice: le prime due sono oggetti Git (SHA-1, 40
# caratteri), la terza è l'impronta del diff (SHA-256, 64).
module AgentReviewAttestation
  REVIEWED_BASE_COMMIT = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
  REVIEWED_SNAPSHOT_TREE = "0f1e2d3c4b5a69788796a5b4c3d2e1f001234567"
  REVIEWED_DIFF_SHA256 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

  # Le tre impronte, ma solo dove la fase le pretende: su una fase riletta sul solo result mandarle
  # sarebbe un rapporto che non torna, ed è giustamente rifiutato.
  def review_attestation(phase)
    return {} unless Agents::PhaseProfile.for(phase.to_s)&.review_depth == Agents::PhaseProfile::REVIEW_DEPTH_DIFF

    { reviewed_base_commit: REVIEWED_BASE_COMMIT, reviewed_snapshot_tree: REVIEWED_SNAPSHOT_TREE,
      reviewed_diff_sha256: REVIEWED_DIFF_SHA256 }
  end

  # CYAU-178 — l'impronta del codice che l'host aveva DAVVERO in mano, misurata sulla sua copia di
  # lavoro. Le fasi che scrivono codice devono portarla: senza, la consegna viene rifiutata.
  OBSERVED_HEAD_SHA = "7c9e6679742501b7d0e8b1f4a3c2d5e6f708192a"

  def observed_head(head_sha: OBSERVED_HEAD_SHA) = { head_sha: }

  # Il blocco `review` completo per una fase: profondità dovuta più le impronte, quando servono.
  def review_for(phase, status: "accepted", summary: "Conforme", **overrides)
    { status:, summary:, depth: Agents::PhaseProfile.for(phase.to_s)&.review_depth }
      .merge(review_attestation(phase)).merge(overrides)
  end
end

RSpec.configure do |config|
  config.include AgentReviewAttestation
end
