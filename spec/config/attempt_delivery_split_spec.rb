# frozen_string_literal: true

require "rails_helper"

# CYRA-741 — il pezzo che riceve il risultato di un agente era il file più delicato del sistema e
# faceva tutto: validava il contratto, decideva se fermare la lavorazione e applicava un effetto
# diverso per ognuna delle cinque fasi, in settecento righe. Aggiungere una fase voleva dire aprirlo
# per intero, e ogni correzione atterrava lì dentro.
#
# Qui si guarda il SORGENTE, non il comportamento: che i pezzi esistano davvero, che la fase li
# risolva da sé e che la consegna non se li sia ripresi. Le prove di comportamento — quelle che
# tengono davvero questa divisione — restano spec/services/agents/attempts/deliver*_spec.rb e gli
# esempi del contratto (spec/contracts/agent_result_v*_spec.rb).
RSpec.describe "La consegna del risultato di un agente non fa tutto", type: :model do
  # Il tetto della Definition of Done. Non è un numero estetico: sopra questa misura il file torna a
  # essere quello che si apre per intero per aggiungere una fase, che è esattamente il problema.
  let(:tetto_righe) { 250 }
  let(:deliver_path) { Rails.root.join("app/services/agents/attempts/deliver.rb") }
  # Solo le righe di CODICE: un commento che NOMINA un piano o un chiarimento è memoria utile e resta
  # dov'è; quello che non deve tornare qui è l'effetto scritto di nuovo.
  let(:codice) { deliver_path.readlines.reject { |riga| riga.strip.start_with?("#") } }

  it "la consegna sta sotto le duecentocinquanta righe" do
    righe = deliver_path.readlines.size

    expect(righe).to be < tetto_righe,
                     "app/services/agents/attempts/deliver.rb misura #{righe} righe " \
                     "(tetto #{tetto_righe}): quello che è tornato dentro va nel pezzo che ha quel compito."
  end

  # Una fase per pezzo: chi cambia cosa succede al triage apre il triage, chi cambia il rilascio in
  # produzione apre il rilascio in produzione. Nessuno dei due apre la consegna.
  it "ogni fase ha il proprio pezzo, e sono pezzi diversi" do
    effetti = Agents::PhaseProfile.phases.to_h { |fase| [ fase, Agents::PhaseProfile.for(fase).effect ] }

    expect(effetti.values).to all(be < Agents::Attempts::Effects::Base)
    expect(effetti.values.uniq.size).to eq(Agents::PhaseProfile.phases.size)
    expect(effetti.fetch("closer_production")).to eq(Agents::Attempts::Effects::CloserProduction)
  end

  # Fail-closed come tutto il resto del profilo: una fase che nessuno ha dichiarato non ha un effetto,
  # e la consegna non ne inventa uno.
  it "una fase sconosciuta non ha nessun effetto" do
    expect(Agents::PhaseProfile.for("unknown")).to be_nil
  end

  # La validazione del contratto è l'altra metà che riempiva il file: vive in un pezzo suo, ed è
  # quello che gli esempi del contratto interrogano.
  it "il contratto della consegna è un pezzo a parte" do
    expect(Agents::Attempts::DeliveryContract::RESULT_VALIDATORS.keys).to contain_exactly(1, 2)
  end

  # Le grafie che dicono «l'effetto è tornato nella consegna». Non sono divieti di stile: ognuna è il
  # cuore di uno dei pezzi estratti, e ritrovarla qui significa che ne esistono di nuovo due copie.
  {
    "il chiarimento del triage" => [ "Clarifications::Ask", "CommentNotifyJob" ],
    "il piano e il lavoro già fatto" => [ "Agents::Plan.create!", "Ticketing::ChangeStatus", "DependencyGuard" ],
    "la proposta dell'autopilot" => [ "DeliveryCandidate", "CandidateVerificationJob" ],
    "le due fasi che rilasciano" => [ "Probes::Bind", "StagingProofJob", "ReleaseProbeJob" ],
    "la validazione del contratto" => [ "JSONSchemer.schema", "RESULT_DEFINITIONS" ]
  }.each do |compito, grafie|
    it "la consegna non riscrive più #{compito}" do
      tornate = grafie.select { |grafia| codice.any? { |riga| riga.include?(grafia) } }

      expect(tornate).to be_empty,
                         "Queste grafie sono tornate nella consegna: #{tornate.join(', ')}. " \
                         "Vivono nel pezzo che ha quel compito, non qui."
    end
  end
end
