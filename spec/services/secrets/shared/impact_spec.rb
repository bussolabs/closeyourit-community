# frozen_string_literal: true

require "rails_helper"

# La fotografia di «chi tocco se cambio questo valore»: la si mostra a schermo prima di ruotare o
# cancellare, e il suo digest è la prova che quella fotografia è ancora valida quando arriva il clic.
# Se cambia il contenuto ma non il digest, la conferma diventa una firma in bianco.
RSpec.describe Secrets::Shared::Impact do
  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:, code: "production") }

  def progetto(nome)
    create(:project, organization:, name: nome).tap do |project|
      create(:project_environment, project:, environment:)
    end
  end

  def valore_condiviso(name: "api_key")
    Secrets::Shared::Save.call(organization:, environment:, name:, value: "secret").value
  end

  it "elenca i progetti che ricevono il valore, in ordine di nome" do
    zeta = progetto("Zeta")
    alfa = progetto("Alfa")
    shared_value = valore_condiviso
    [ zeta, alfa ].each { |project| Secrets::Shared::Delegate.call(shared_value:, project:) }

    payload = described_class.call(shared_value: shared_value.reload, effect: :rotate).value

    expect(payload["effect"]).to eq("rotate")
    expect(payload["name"]).to eq("API_KEY")
    expect(payload["projects"].map { |row| row["name"] }).to eq(%w[Alfa Zeta])
    expect(payload["projects"].first).to include("id" => alfa.id, "environment" => "production")
  end

  # Dire che il valore finirà anche su GitHub cambia il peso della decisione: va scritto solo quando
  # è vero, cioè quando quel progetto ha l'invio acceso.
  it "dice quale repository riceverà il valore, solo dove l'invio è acceso" do
    con_invio = progetto("Con invio")
    senza_invio = progetto("Senza invio")
    create(:github_repository, project: con_invio, sync_secrets: true, full_name: "bussolabs/con-invio")
    create(:github_repository, project: senza_invio, sync_secrets: false)
    shared_value = valore_condiviso
    [ con_invio, senza_invio ].each { |project| Secrets::Shared::Delegate.call(shared_value:, project:) }

    projects = described_class.call(shared_value: shared_value.reload, effect: :rotate).value["projects"]

    expect(projects.find { |row| row["id"] == con_invio.id }["repository"]).to eq("bussolabs/con-invio")
    expect(projects.find { |row| row["id"] == senza_invio.id }["repository"]).to be_nil
  end

  it "un valore che nessuno riceve ha una lista vuota, non un errore" do
    payload = described_class.call(shared_value: valore_condiviso, effect: :delete).value

    expect(payload["effect"]).to eq("delete")
    expect(payload["projects"]).to eq([])
    expect(payload["digest"]).to be_present
  end

  describe "il digest" do
    let(:shared_value) { valore_condiviso }

    it "è stabile a parità di fotografia" do
      primo = described_class.call(shared_value:, effect: :rotate).value["digest"]
      secondo = described_class.call(shared_value: shared_value.reload, effect: :rotate).value["digest"]

      expect(primo).to eq(secondo)
    end

    # La conferma di una rotazione non deve valere per una cancellazione: sono due decisioni diverse
    # sullo stesso elenco di progetti.
    it "cambia con l'effetto, a parità di progetti" do
      rotazione = described_class.call(shared_value:, effect: :rotate).value["digest"]
      cancellazione = described_class.call(shared_value:, effect: :delete).value["digest"]

      expect(rotazione).not_to eq(cancellazione)
    end

    it "cambia quando un progetto entra o esce dall'elenco" do
      prima = described_class.call(shared_value:, effect: :rotate).value["digest"]
      Secrets::Shared::Delegate.call(shared_value:, project: progetto("Nuovo"))

      dopo = described_class.call(shared_value: shared_value.reload, effect: :rotate).value["digest"]

      expect(dopo).not_to eq(prima)
    end

    it "cambia quando un progetto accende l'invio verso GitHub" do
      project = progetto("Con repo")
      repository = create(:github_repository, project:, sync_secrets: false)
      Secrets::Shared::Delegate.call(shared_value:, project:)
      prima = described_class.call(shared_value: shared_value.reload, effect: :rotate).value["digest"]

      repository.update!(sync_secrets: true)

      expect(described_class.call(shared_value: shared_value.reload, effect: :rotate).value["digest"])
        .not_to eq(prima)
    end
  end
end
