# frozen_string_literal: true

require "rails_helper"

# CYRA-624 — quello che si andrà a cercare si congela nell'istante della consegna: la versione decisa
# dal server e il codice sigillato. Ricavarli dopo dall'etichetta osservata vorrebbe dire chiedere
# alla cosa osservata se se stessa è giusta.
RSpec.describe Agents::Probes::Bind do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:sealed_sha) { "3f2a91c0d4e6b8079a1c5f3d2e7b4a6c8d0f1e29" }

  before { assigned_version(workflow, "closer_production", version: "v0.30.0", sha: sealed_sha) }

  it "aggancia una prova sola, con dentro il numero e il codice decisi prima del rilascio" do
    congela_piano!(workflow, kind: "deploy_smoke", environment_id: 42)

    esito = described_class.call(workflow:)

    expect(esito).to be_ok
    prova = workflow.probes.live.sole
    expect(prova.expected).to eq("version" => "v0.30.0", "sha" => sealed_sha,
                                 "repo" => repository.full_name, "environment_id" => 42)
    expect(prova.next_check_at).to be_present
  end

  # Idempotente: una seconda consegna della stessa produzione non aggancia una seconda prova. Due
  # prove vive sarebbero due verità sullo stesso rilascio.
  it "chiamata due volte non aggancia una seconda prova" do
    congela_piano!(workflow, kind: "deploy_smoke", environment_id: 42)

    prima = described_class.call(workflow:).value
    seconda = described_class.call(workflow:).value

    expect(seconda).to eq(prima)
    expect(workflow.probes.live.count).to eq(1)
  end

  # Un progetto che non dichiara come si prova che un rilascio è vivo non deve far aspettare un'ora
  # per niente: si dice subito, e con parole diverse da quelle della scadenza.
  it "una prova di un tipo che non sa osservare non aggancia niente, e lo dice subito" do
    congela_piano!(workflow, kind: "merge")

    esito = described_class.call(workflow:)

    expect(esito).to be_err
    expect(esito.error.code).to eq("R409-WORKFLOW-011")
    expect(esito.error.message).to include("non dichiara come si prova")
    expect(workflow.probes).to be_empty
  end

  it "senza piano congelato non aggancia niente" do
    esito = described_class.call(workflow:)

    expect(esito).to be_err
    expect(workflow.probes).to be_empty
  end

  # Senza il numero deciso dal server non c'è niente da confrontare: la prova sarebbe una prova di
  # niente.
  # CYRA-625 — lo scaffale delle immagini si legge solo con una credenziale di sola lettura, e oggi
  # ne esiste una sola: quella che SCRIVE, la stessa con cui tutta la flotta pubblica. Finché non ce
  # n'è una di lettura, la prova non si arma: si dice subito, con parole sue.
  it "il registro delle immagini non aggancia niente e lo dice con parole sue" do
    congela_piano!(workflow, kind: "publish", registry: "docker", package: "closeyourit/agent")

    esito = described_class.call(workflow:)

    expect(esito.error.code).to eq("R409-WORKFLOW-012")
    expect(esito.error.message).to include("credenziale")
    expect(workflow.probes).to be_empty
  end

  it "un pacchetto pubblico aggancia la prova con scaffale e nome congelati" do
    congela_piano!(workflow, kind: "publish", registry: "npm", package: "@closeyourit/cli")

    expect(described_class.call(workflow:)).to be_ok
    expect(workflow.probes.live.sole.expected)
      .to include("registry" => "npm", "package" => "@closeyourit/cli", "version" => "v0.30.0")
  end

  it "senza il numero assegnato dal server non aggancia niente" do
    congela_piano!(workflow, kind: "deploy_smoke", environment_id: 42)
    Agents::ReleaseAssignment.delete_all

    expect(described_class.call(workflow:)).to be_err
  end
end
