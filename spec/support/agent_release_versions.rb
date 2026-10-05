# frozen_string_literal: true

# CYRA-621 — il numero di versione lo assegna il server prima che la fase parta, e per sapere da dove
# partire chiede a GitHub quali versioni sono già uscite. Ogni prova che prende in carico un rilascio
# passa quindi da lì: senza un finto, la presa in carico fallisce per un motivo che non è quello in
# prova, e il rosso sembra del pezzo sbagliato.
#
# Sta qui e non copiato in ogni file perché la forma della risposta è un contratto: `tags` restituisce
# i NOMI, e sbagliarla in un solo posto darebbe un rosso che sembra del codice.
module AgentReleaseVersions
  # Le versioni già uscite sul deposito. Vuoto = nessuna, che è il caso di un progetto nuovo.
  def versioni_uscite(*nomi)
    finto = instance_double(Github::Client)
    allow(finto).to receive(:tags).and_return(nomi.flatten)
    allow(Github::Client).to receive(:new).and_return(finto)
    finto
  end

  # Il commit che il sistema ha VISTO atterrare sulla linea principale: senza, la versione definitiva
  # non si assegna e la fase non parte (R409-WORKFLOW-010). Sta nel result del tentativo di staging,
  # che è audit immutabile — non nel ramo, che si muove.
  def commit_verificato!(workflow, sha: "a" * 40)
    create(:agent_attempt, organization: workflow.organization, workflow:, phase: "closer_staging",
                           result: { "state" => "staging-released", "commit" => sha })
    workflow.update!(closer_staging_verified_at: workflow.closer_staging_verified_at || Time.current)
    sha
  end

  # L'assegnazione che il server ha scritto prima che la fase partisse. Le consegne di rilascio
  # devono portare QUEL numero: senza la riga, la consegna è rifiutata — ed è il punto.
  def assigned_version(workflow, phase, version:, sha: nil)
    Agents::ReleaseAssignment.create!(
      workflow:, github_repository: workflow.ticket.project.github_repository,
      execution_phase: phase, version:, sha:, baseline_tag: "v0.0.1"
    )
  end
end

RSpec.configure do |config|
  config.include AgentReleaseVersions
end
