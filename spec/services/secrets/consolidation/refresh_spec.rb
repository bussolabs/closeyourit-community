# frozen_string_literal: true

require "rails_helper"

# Il giro che tiene aggiornata la lista delle proposte. La parte che conta è la memoria: «non
# proporre più» deve resistere al giro della notte dopo, altrimenti il pulsante non vale niente.
RSpec.describe Secrets::Consolidation::Refresh do
  let(:organization) { create(:organization) }
  let(:production) { create(:environment, organization:, code: "production") }
  let(:staging) { create(:environment, organization:, code: "staging") }
  let!(:owner) { create(:membership, organization:, role: :owner).account }

  def progetto(nome, *environments)
    project = create(:project, organization:, name: nome)
    environments.each { |environment| create(:project_environment, project:, environment:) }
    project
  end

  def segreto(project, environment, name, value)
    create(:secret_variable, project:, organization:, environment:, name:, value:)
  end

  def avvisi_in_app
    Alerting::Notification.where(event_type: :secret_consolidation_suggested).via_in_app
  end

  def duplica(valore: "valore-condiviso-lungo", environment: production, nomi: %w[API_KEY CHIAVE_API])
    nomi.each_with_index.map do |nome, indice|
      project = progetto("progetto-#{environment.code}-#{indice}-#{nome}", environment)
      segreto(project, environment, nome, valore)
    end
  end

  it "apre una proposta per il valore ripetuto e la descrive" do
    duplica

    expect { described_class.call(organization:) }
      .to change { Secrets::Consolidation::Suggestion.count }.by(1)

    suggestion = Secrets::Consolidation::Suggestion.last
    expect(suggestion).to be_status_open
    expect(suggestion.projects_count).to eq(2)
    expect(suggestion.suggested_name).to eq("API_KEY")
    expect(suggestion.environment).to eq(production)
    expect(suggestion.value_fingerprint).to eq(Secrets::Consolidation::Fingerprint.for("valore-condiviso-lungo"))
  end

  it "non tiene il valore in chiaro da nessuna parte" do
    duplica

    described_class.call(organization:)

    expect(Secrets::Consolidation::Suggestion.last.attributes.values.map(&:to_s))
      .not_to include(a_string_including("valore-condiviso-lungo"))
  end

  it "ripassando non crea un doppione e aggiorna il conteggio" do
    duplica
    described_class.call(organization:)

    terzo = progetto("terzo", production)
    segreto(terzo, production, "API_KEY", "valore-condiviso-lungo")

    expect { described_class.call(organization:) }
      .not_to change { Secrets::Consolidation::Suggestion.count }
    expect(Secrets::Consolidation::Suggestion.last.projects_count).to eq(3)
  end

  it "avvisa chi tiene i secret dell'organizzazione, una volta sola" do
    duplica

    expect { described_class.call(organization:) }
      .to change { avvisi_in_app.count }.by(1)

    expect { described_class.call(organization:) }.not_to change { avvisi_in_app.count }
  end

  it "manda la notifica alla proposta, senza nominare progetti né valore" do
    duplica
    described_class.call(organization:)

    notifica = avvisi_in_app.last
    suggestion = Secrets::Consolidation::Suggestion.last

    expect(notifica.subject).to eq(suggestion)
    expect(notifica.project).to be_nil
    expect(notifica.account).to eq(owner)
    expect(notifica.url).to eq("/member/vault/consolidations/#{suggestion.id}")
    expect("#{notifica.title} #{notifica.body}").not_to include("valore-condiviso-lungo", "API_KEY")
  end

  describe "la memoria delle decisioni" do
    it "non riapre una proposta archiviata con «non proporre più»" do
      duplica
      described_class.call(organization:)
      suggestion = Secrets::Consolidation::Suggestion.last
      suggestion.update!(status: :dismissed, dismissed_at: Time.current)

      described_class.call(organization:)

      expect(suggestion.reload).to be_status_dismissed
    end

    it "non manda una seconda notifica per una proposta archiviata" do
      duplica
      described_class.call(organization:)
      Secrets::Consolidation::Suggestion.last.update!(status: :dismissed, dismissed_at: Time.current)

      expect { described_class.call(organization:) }.not_to change { avvisi_in_app.count }
    end

    # Il valore è stato spostato nell'organizzazione, poi qualcuno lo ha ricopiato a mano in due
    # progetti nuovi: il fatto è di nuovo vero e va di nuovo detto.
    it "riapre una proposta già accettata se il valore torna a essere ripetuto" do
      duplica
      described_class.call(organization:)
      suggestion = Secrets::Consolidation::Suggestion.last
      suggestion.update!(status: :promoted, promoted_at: 1.week.ago)

      expect { described_class.call(organization:) }.to change { suggestion.reload.status }.to("open")
      expect(suggestion.promoted_at).to be_nil
    end
  end

  it "chiude la proposta quando il valore non è più ripetuto" do
    variabili = duplica
    described_class.call(organization:)

    variabili.last.update!(value: "un-altro-valore-lungo")

    expect { described_class.call(organization:) }
      .to change { Secrets::Consolidation::Suggestion.count }.to(0)
  end

  # Il giro mirato che segue un salvataggio guarda un solo ambiente: non deve poter cancellare
  # proposte di ambienti che non ha nemmeno interrogato.
  it "restringendo l'ambiente non tocca le proposte degli altri" do
    duplica(environment: production)
    duplica(environment: staging, valore: "un-altro-valore-lungo")
    described_class.call(organization:)
    expect(Secrets::Consolidation::Suggestion.count).to eq(2)

    Secrets::Variable.where(environment: staging).last.update!(value: "valore-diverso-ancora")
    described_class.call(organization:, environment: staging)

    expect(Secrets::Consolidation::Suggestion.pluck(:environment_id)).to eq([ production.id ])
  end
end
