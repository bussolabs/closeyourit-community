# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Workflows::ApprovePlan do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:cto) do
    create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
  end
  let(:attempt) { create(:agent_attempt, organization:, workflow:) }
  let!(:plan) do
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Piano", scenarios: [],
                         definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot")
  end

  before { workflow.update!(triaged_at: 2.minutes.ago, planned_at: Time.current) }

  it "usa il CTO organizzativo come fallback e timbra la versione corrente" do
    organization.update!(cto:)

    result = described_class.call(workflow:, actor: cto)

    expect(result).to be_ok
    expect(plan.reload).to have_attributes(approved_by: cto, approved_at: be_present)
    expect(workflow.reload).to have_attributes(approved_by: cto, phase: "autopilot_queued")
  end

  it "l'override di progetto vince sul CTO organizzativo" do
    override = create(:account).tap do |account|
      create(:membership, account:, organization:)
      create(:project_membership, account:, project:)
    end
    organization.update!(cto:)
    project.update!(cto: override)

    expect(described_class.call(workflow:, actor: cto).error.code).to eq("R403-WORKFLOW-001")
    expect(described_class.call(workflow:, actor: override)).to be_ok
  end

  # CYRA-998 — the plans association is already ordered by version: an extra descending order only
  # breaks ties, so the decision landed on version 1 while the agent worked on the latest one.
  context "with a rewritten plan" do
    let!(:latest) do
      Agents::Plan.create!(workflow:, attempt:, technical_analysis: "Rewritten plan", scenarios: [],
                           definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot")
    end

    before { organization.update!(cto:) }

    it "approves the latest version, not the first one" do
      expect(described_class.call(workflow:, actor: cto)).to be_ok
      expect(latest.reload.approved_at).to be_present
      expect(plan.reload.approved_at).to be_nil
    end

    it "asks changes on the latest version, not the first one" do
      expect(Agents::Workflows::RequestPlanChanges.call(workflow:, actor: cto, reason: "Plainer words")).to be_ok
      expect(latest.reload.change_request).to eq("Plainer words")
      expect(plan.reload.change_request).to be_nil
    end
  end

  it "si blocca esplicitamente quando manca il CTO" do
    expect(described_class.call(workflow:, actor: cto).error.code).to eq("R409-WORKFLOW-002")
  end

  it "richiedere modifiche marca la versione e riaccoda il planner" do
    organization.update!(cto:)

    result = Agents::Workflows::RequestPlanChanges.call(workflow:, actor: cto, reason: "Aggiungere rollback")

    expect(result).to be_ok
    expect(plan.reload.change_request).to eq("Aggiungere rollback")
    expect(workflow.reload).to have_attributes(planned_at: nil, phase: "planning")
  end

  # CYRA-218: una decisione presa su un piano vale anche come decisione sul blocco. Se il blocco
  # sopravvivesse all'approvazione, il workflow resterebbe fuori dalla coda pur avendo un piano
  # approvato: fermo per sempre, senza che nulla lo dica.
  describe "sblocco implicito di una lavorazione ferma (CYRA-218)" do
    before do
      organization.update!(cto:)
      workflow.update!(blocked_at: Time.current, blocked_phase: "planner", blocked_kind: "attempt_limit", blocked_reason: "Bocciato 2 volte")
    end

    it "approvare il piano sblocca la lavorazione" do
      expect(described_class.call(workflow:, actor: cto)).to be_ok

      expect(workflow.reload).to have_attributes(blocked_at: nil, blocked_phase: nil, blocked_reason: nil)
    end

    it "richiedere modifiche sblocca la lavorazione e la rimette in coda" do
      expect(Agents::Workflows::RequestPlanChanges.call(workflow:, actor: cto, reason: "Rifallo")).to be_ok

      expect(workflow.reload.blocked_at).to be_nil
      expect(workflow.ready_execution_phase).to eq("planner")
    end
  end
  # ── CYRA-610 ──────────────────────────────────────────────────────────────────────────────────
  #
  # Prima, approvare un piano non fissava niente. Dove il lavoro poteva nascere veniva riletto a ogni
  # presa in carico — se qualcuno cambiava il collegamento fra progetto e archivio nel frattempo, il
  # lavoro nasceva altrove e nessuno se ne accorgeva. E la prova che dice «fatto» non era scritta da
  # nessuna parte: la sceglieva chi esegue, alla fine, quando era tardi per discuterne.
  describe "le due decisioni che l'approvazione congela" do
    before { organization.update!(cto:) }

    it "fissa su quale archivio il lavoro può nascere, e da quale punto" do
      create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails",
                                 default_branch: "main", release_probe: :merge)

      expect(described_class.call(workflow:, actor: cto)).to be_ok
      expect(plan.reload.candidate_items).to eq([ { "repo" => "bussolabs/closeyourit-rails", "base" => "main" } ])
    end

    it "fissa quale prova dirà «fatto», con le coordinate che quella prova richiede" do
      repository = create(:github_repository, :with_env_mapping, project:)
      repository.update!(release_probe: :deploy_smoke)

      expect(described_class.call(workflow:, actor: cto)).to be_ok
      expect(plan.reload.completion_probe).to eq(
        "kind" => "deploy_smoke", "repo" => repository.full_name,
        "environment_id" => repository.production_environment_id
      )
    end

    # CYRA-625 — la prova del pacchetto porta con sé le SUE coordinate, congelate come il resto: fra
    # l'approvazione e il rilascio qualcuno può cambiarle sul progetto, e la prova deve andare a
    # cercare quello che si era deciso di cercare.
    it "sulla prova del pacchetto congela scaffale e nome, e niente di più" do
      create(:github_repository, project:, full_name: "bussolabs/closeyourit-cli", release_probe: :publish,
                                 registry: :npm, package_name: "@closeyourit/cli")

      expect(described_class.call(workflow:, actor: cto)).to be_ok
      expect(plan.reload.completion_probe).to eq("kind" => "publish", "repo" => "bussolabs/closeyourit-cli",
                                                 "registry" => "npm", "package" => "@closeyourit/cli")
    end

    it "sulla prova del codice unito non inventa coordinate che non servono" do
      create(:github_repository, project:, full_name: "bussolabs/closeyourit-cli", release_probe: :merge)

      expect(described_class.call(workflow:, actor: cto)).to be_ok
      expect(plan.reload.completion_probe).to eq("kind" => "merge", "repo" => "bussolabs/closeyourit-cli")
    end

    # Fermare il lavoro alla porta d'ingresso perché manca un dato che serve alla porta d'uscita non
    # aggiunge sicurezza: toglie l'unica strada. Alla fine sarà una persona a dire «fatto».
    it "senza archivio collegato l'approvazione riesce lo stesso, e non congela niente" do
      expect(project.github_repository).to be_nil

      expect(described_class.call(workflow:, actor: cto)).to be_ok
      expect(plan.reload).to have_attributes(approved_at: be_present, candidate_items: nil, completion_probe: nil)
    end

    it "senza una prova decisa l'approvazione riesce lo stesso, e non congela niente" do
      create(:github_repository, project:, release_probe: nil)

      expect(described_class.call(workflow:, actor: cto)).to be_ok
      expect(plan.reload).to have_attributes(approved_at: be_present, candidate_items: nil, completion_probe: nil)
    end

    # QUALE versione del piano è quella approvata si fissa SEMPRE: è l'identità di ciò che è stato
    # approvato, e non dipende da come è configurato il progetto. Chi eseguirà dovrà dichiarare di
    # lavorare su questa.
    it "fissa quale versione del piano è quella approvata, anche quando il resto non era componibile" do
      expect(described_class.call(workflow:, actor: cto)).to be_ok
      expect(workflow.reload).to have_attributes(frozen_plan_id: plan.id, plan_frozen_at: be_present)
    end

    # Non è mai il payload dell'agente a comporla: si legge solo ciò che una persona ha configurato.
    it "legge il collegamento del progetto, non il piano scritto dall'agente" do
      create(:github_repository, project:, full_name: "bussolabs/vero", default_branch: "principale",
                                 release_probe: :merge)
      plan.update!(technical_analysis: "Lavorare su bussolabs/finto, ramo inventato")

      expect(described_class.call(workflow:, actor: cto)).to be_ok
      expect(plan.reload.candidate_items).to eq([ { "repo" => "bussolabs/vero", "base" => "principale" } ])
    end

    # Approvare un piano non chiede niente a GitHub, e deve restare così: la transazione non può
    # restare appesa perché un servizio esterno non risponde.
    it "non chiama GitHub" do
      create(:github_repository, project:, release_probe: :merge)
      allow(Github::Client).to receive(:new).and_raise("nessuna chiamata a GitHub durante l'approvazione")

      expect(described_class.call(workflow:, actor: cto)).to be_ok
    end
  end
end
