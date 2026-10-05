# frozen_string_literal: true

require "rails_helper"

# Il gesto che sposta davvero il valore. La cosa da provare non è il caso felice ma il confine: fra il
# momento in cui la variabile locale sparisce e quello in cui la delega la sostituisce il progetto non
# ha quel segreto, quindi o si sposta tutto o non si sposta niente.
RSpec.describe Secrets::Consolidation::Promote do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:production) { create(:environment, organization:, code: "production") }
  let(:actor) { create(:account) }

  def progetto(nome)
    project = create(:project, organization:, name: nome)
    create(:project_environment, project:, environment: production)
    project
  end

  let(:uno) { progetto("uno") }
  let(:due) { progetto("due") }
  let(:valore) { "valore-condiviso-lungo" }

  def segreto(project, name, value = valore)
    create(:secret_variable, project:, organization:, environment: production, name:, value:)
  end

  def proposta
    segreto(uno, "API_KEY")
    segreto(due, "CHIAVE_API")
    Secrets::Consolidation::Refresh.call(organization:)
    Secrets::Consolidation::Suggestion.last
  end

  def digest_of(suggestion) = Secrets::Consolidation::Impact.call(suggestion:).value["digest"]

  it "rifiuta più alias nello stesso progetto prima di spostare o cancellare variabili" do
    suggestion = proposta
    segreto(uno, "SECOND_API_KEY")
    confirmation_digest = digest_of(suggestion)

    expect {
      result = described_class.call(suggestion:, actor:, confirmation_digest:)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-CONSOLIDATION-002")
      expect(result.error.message).to eq(I18n.t("member.secrets.origins.alias_conflict_body"))
    }.not_to change { [ Secrets::Variable.count, Secrets::Shared::Variable.count,
                        Secrets::Shared::Delegation.count, Secrets::Event.count ] }
    expect(suggestion.reload).to be_status_open
  end

  it "sposta il valore nell'organizzazione e delega i progetti, ciascuno col suo nome" do
    suggestion = proposta

    result = described_class.call(suggestion:, actor:, confirmation_digest: digest_of(suggestion))

    expect(result).to be_ok
    shared = organization.shared_secret_variables.find_by(name: "API_KEY")
    expect(shared).to be_present
    expect(shared.values.first.value).to eq(valore)
    expect(Secrets::Bundle.call(project: uno, environment: production).value).to eq("API_KEY" => valore)
    expect(Secrets::Bundle.call(project: due, environment: production).value).to eq("CHIAVE_API" => valore)
  end

  it "toglie le copie locali" do
    suggestion = proposta

    described_class.call(suggestion:, actor:, confirmation_digest: digest_of(suggestion))

    expect(Secrets::Variable.where(project: [ uno, due ])).to be_empty
  end

  it "non scrive un alias quando il progetto usa già il nome dell'organizzazione" do
    suggestion = proposta

    described_class.call(suggestion:, actor:, confirmation_digest: digest_of(suggestion))

    expect(uno.shared_secret_delegations.first.local_name).to be_nil
    expect(due.shared_secret_delegations.first.local_name).to eq("CHIAVE_API")
  end

  it "accetta il nome e gli alias scelti da chi conferma" do
    suggestion = proposta

    described_class.call(suggestion:, actor:, name: "chiave_unica",
                         local_names: { uno.id => "mia_chiave" },
                         confirmation_digest: digest_of(suggestion))

    expect(organization.shared_secret_variables.pluck(:name)).to eq([ "CHIAVE_UNICA" ])
    expect(Secrets::Bundle.call(project: uno, environment: production).value).to have_key("MIA_CHIAVE")
    expect(Secrets::Bundle.call(project: due, environment: production).value).to have_key("CHIAVE_API")
  end

  it "segna la proposta come accettata e la lega al secret creato" do
    suggestion = proposta

    described_class.call(suggestion:, actor:, confirmation_digest: digest_of(suggestion))

    expect(suggestion.reload).to be_status_promoted
    expect(suggestion.promoted_by).to eq(actor)
    expect(suggestion.shared_variable).to eq(organization.shared_secret_variables.first)
  end

  it "lascia scritto nell'audit di ogni progetto che il valore si è spostato, non che è sparito" do
    suggestion = proposta

    described_class.call(suggestion:, actor:, confirmation_digest: digest_of(suggestion))

    expect(uno.secret_events.where(action: "consolidated").pluck(:name)).to eq([ "API_KEY" ])
    expect(uno.secret_events.where(action: "deleted")).to be_empty
    expect(Secrets::Shared::Event.where(action: "delegated").count).to eq(2)
  end

  it "fa ripartire l'invio verso GitHub per i progetti che lo usano" do
    repository = create(:github_repository, project: uno, sync_secrets: true)
    suggestion = proposta

    described_class.call(suggestion:, actor:, confirmation_digest: digest_of(suggestion))

    expect(Secrets::Github::SyncJob).to have_been_enqueued.with(github_repository_id: repository.id)
  end

  describe "quando l'organizzazione tiene già quel valore" do
    it "delega il secret che esiste invece di crearne un secondo identico" do
      Secrets::Shared::Save.call(organization:, environment: production, name: "GIA_QUI", value: valore)
      suggestion = proposta

      described_class.call(suggestion:, actor:, name: "NUOVO_NOME", confirmation_digest: digest_of(suggestion))

      expect(organization.shared_secret_variables.pluck(:name)).to eq([ "GIA_QUI" ])
      expect(Secrets::Bundle.call(project: uno, environment: production).value).to eq("API_KEY" => valore)
    end
  end

  # Lo stesso nome duplicato su due ambienti sono DUE proposte (i valori sono diversi, quindi le
  # impronte pure), ma nell'organizzazione deve nascere UN secret solo con due valori: un secondo
  # secret con lo stesso nome non potrebbe nemmeno esistere.
  it "accettando due ambienti nasce un secret solo con due valori" do
    staging = create(:environment, organization:, code: "staging")
    [ uno, due ].each { |project| create(:project_environment, project:, environment: staging) }
    prima = proposta
    described_class.call(suggestion: prima, actor:, name: "API_KEY", confirmation_digest: digest_of(prima))

    create(:secret_variable, project: uno, organization:, environment: staging, name: "API_KEY", value: "valore-di-staging")
    create(:secret_variable, project: due, organization:, environment: staging, name: "CHIAVE_API", value: "valore-di-staging")
    Secrets::Consolidation::Refresh.call(organization:)
    seconda = Secrets::Consolidation::Suggestion.status_open.last

    result = described_class.call(suggestion: seconda, actor:, name: "API_KEY", confirmation_digest: digest_of(seconda))

    expect(result).to be_ok
    expect(organization.shared_secret_variables.count).to eq(1)
    expect(organization.shared_secret_variables.first.values.count).to eq(2)
    expect(Secrets::Bundle.call(project: uno, environment: staging).value).to eq("API_KEY" => "valore-di-staging")
  end

  # Gli scostamenti personali si applicano PER NOME: l'alias conserva il nome che il progetto usava,
  # quindi chi aveva un valore su misura continua a riceverlo.
  it "lascia in piedi lo scostamento personale di chi ne aveva uno" do
    persona = create(:account)
    create(:membership, account: persona, organization:, role: :member)
    suggestion = proposta
    Secrets::Override.create!(account: persona, project: due, environment: production, organization:,
                              name: "CHIAVE_API", value: "valore-su-misura")

    described_class.call(suggestion:, actor:, confirmation_digest: digest_of(suggestion))

    expect(Secrets::Bundle.call(project: due, environment: production, account: persona).value)
      .to eq("CHIAVE_API" => "valore-su-misura")
  end

  describe "la conferma" do
    it "senza conferma non sposta niente" do
      suggestion = proposta

      result = described_class.call(suggestion:, actor:)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CONSOLIDATION-001")
      expect(Secrets::Variable.where(project: [ uno, due ]).count).to eq(2)
    end

    # È il caso per cui la conferma esiste: fra la pagina e il clic il mondo è cambiato, e si sta per
    # scrivere su qualcosa di diverso da quello che si è letto.
    it "scade quando nel frattempo un terzo progetto prende lo stesso valore" do
      suggestion = proposta
      digest = digest_of(suggestion)
      segreto(progetto("tre"), "API_KEY")

      result = described_class.call(suggestion:, actor:, confirmation_digest: digest)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CONSOLIDATION-001")
    end

    it "rifiuta quando il valore non è più ripetuto" do
      suggestion = proposta
      digest = digest_of(suggestion)
      Secrets::Variable.find_by(project: due).update!(value: "un-altro-valore-lungo")

      result = described_class.call(suggestion:, actor:, confirmation_digest: digest)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-CONSOLIDATION-002")
    end
  end

  describe "quando qualcosa non si può fare" do
    # Se una sola delega non passa, i progetti già toccati devono ritrovarsi il loro segreto: a metà
    # strada c'è un'applicazione senza la sua chiave.
    it "non lascia niente a metà" do
      suggestion = proposta
      digest = digest_of(suggestion)
      due.project_environments.find_by(environment: production).update!(secrets_enabled: false)

      result = described_class.call(suggestion:, actor:, confirmation_digest: digest)

      expect(result).to be_err
      expect(Secrets::Variable.where(project: [ uno, due ]).count).to eq(2)
      expect(organization.shared_secret_variables).to be_empty
      expect(suggestion.reload).to be_status_open
    end

    it "rifiuta un nome fuori formato senza toccare i progetti" do
      suggestion = proposta

      result = described_class.call(suggestion:, actor:, name: "nome con spazi",
                                    confirmation_digest: digest_of(suggestion))

      expect(result).to be_err
      expect(Secrets::Variable.where(project: [ uno, due ]).count).to eq(2)
    end
  end
end
