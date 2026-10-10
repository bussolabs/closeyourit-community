# frozen_string_literal: true

require "rails_helper"

# Le REGOLE del repository agganciato. La lista di campi ammessi è la parte delicata: sotto si fa uno
# `slice`, quindi un campo dimenticato non dà errore — sparisce, e il canale risponde «salvato» senza
# aver cambiato niente. È esattamente il guasto silenzioso di CYRA-605 e CYRA-625.
RSpec.describe Github::Repositories::Save do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:production) do
    create(:environment, organization:, code: "production").tap { |env| project.environments << env }
  end
  let(:repository) { create(:github_repository, project:) }

  it "salva il ramo principale" do
    result = described_class.call(repository:, attributes: { default_branch: "develop" })

    expect(result).to be_ok
    expect(repository.reload.default_branch).to eq("develop")
  end

  it "salva la mappa stabilità→ambiente" do
    staging = create(:environment, organization:, code: "staging")
    project.environments << staging

    described_class.call(repository:, attributes: { production_environment_id: production.id,
                                                    staging_environment_id: staging.id })

    expect(repository.reload.production_environment).to eq(production)
    expect(repository.staging_environment).to eq(staging)
  end

  # CYRA-1072 — a plan approved before the project had a release proof stayed out of the queue for good,
  # while the page promised it would restart by itself once the proof was set.
  describe "plans approved without a release proof" do
    let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
    let(:workflow) { ticket.agent_workflow }
    let!(:plan) do
      Agents::Plan.create!(workflow:, attempt: create(:agent_attempt, organization:, workflow:), technical_analysis: "Plan",
                           scenarios: [], definition_of_done: [ "RSpec" ], notes: [], ticket_snapshot_digest: "snapshot",
                           approved_at: 1.hour.ago).tap { |p| workflow.update!(approved_at: 1.hour.ago, frozen_plan_id: p.id) }
    end

    it "freezes the decision they were missing once the proof is set" do
      described_class.call(repository:, attributes: { release_probe: "merge" })

      expect(plan.reload.candidate_items).to eq([ { "repo" => repository.full_name, "base" => repository.default_branch } ])
      expect(plan.completion_probe).to include("kind" => "merge")
    end

    it "leaves a plan of a cancelled run alone" do
      workflow.update!(cancelled_at: Time.current)

      described_class.call(repository:, attributes: { release_probe: "merge" })

      expect(plan.reload.candidate_items).to be_nil
    end
  end

  it "salva la prova di rilascio: senza, la scelta si perderebbe rispondendo «fatto»" do
    result = described_class.call(repository:, attributes: { release_probe: "deploy_smoke",
                                                             production_environment_id: production.id })

    expect(result).to be_ok
    expect(repository.reload.release_probe).to eq("deploy_smoke")
  end

  it "salva le coordinate dello scaffale insieme alla prova che le pretende" do
    result = described_class.call(repository:, attributes: { release_probe: "publish", registry: "npm",
                                                             package_name: "@bussolabs/app" })

    expect(result).to be_ok
    expect(repository.reload).to have_attributes(release_probe: "publish", registry: "npm",
                                                 package_name: "@bussolabs/app")
  end

  it "accetta le chiavi come stringhe: i parametri di una richiesta non arrivano mai come simboli" do
    described_class.call(repository:, attributes: { "default_branch" => "release" })

    expect(repository.reload.default_branch).to eq("release")
  end

  # I toggle si salvano da soli dal controller (auto-save), non da qui: un campo fuori lista che
  # passasse cambierebbe stato senza che nessuno l'abbia chiesto da questa strada.
  it "ignora i campi fuori dalla lista invece di scriverli" do
    described_class.call(repository:, attributes: { default_branch: "develop", full_name: "altro/repo",
                                                    sync_secrets: true, repo_id: 1 })

    expect(repository.reload.default_branch).to eq("develop")
    expect(repository.full_name).not_to eq("altro/repo")
    expect(repository.sync_secrets).to be(false)
  end

  it "«il rilascio in produzione è in piedi» senza ambiente di produzione è un errore leggibile" do
    result = described_class.call(repository:, attributes: { release_probe: "deploy_smoke" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-001")
    expect(result.error.details).to have_key(:release_probe)
    expect(repository.reload.release_probe).to be_nil
  end

  it "«il pacchetto è pubblicato» senza scaffale né nome è un errore, non un salvataggio a metà" do
    result = described_class.call(repository:, attributes: { release_probe: "publish" })

    expect(result).to be_err
    expect(result.error.details).to have_key(:registry)
    expect(repository.reload.release_probe).to be_nil
  end

  it "un valore che non esiste risponde «non esiste», non con un guasto del server" do
    result = described_class.call(repository:, attributes: { release_probe: "telepatia" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-001")
  end

  it "un ambiente che il progetto non dichiara non entra nella mappa" do
    estraneo = create(:environment, organization:, code: "preview")

    result = described_class.call(repository:, attributes: { preview_environment_id: estraneo.id })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-GITHUB-001")
    expect(repository.reload.preview_environment).to be_nil
  end
end
