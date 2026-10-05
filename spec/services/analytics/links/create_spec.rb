# frozen_string_literal: true

require "rails_helper"

# Pubblicare la dashboard porta dati fuori dall'organizzazione: l'indirizzo imprevedibile è la chiave
# d'accesso, la password è il lucchetto in più, e CYRA-697 pretende che resti scritto CHI ha pubblicato.
RSpec.describe Analytics::Links::Create do
  let(:project) { create(:project) }
  let(:actor) { create(:account) }

  it "crea un link attivo con un indirizzo imprevedibile e senza password" do
    result = described_class.call(project:, actor:)

    expect(result).to be_ok
    link = result.value
    expect(link).to be_persisted
    expect(link).to be_enabled
    expect(link.slug).to be_present
    expect(link).not_to be_password_protected
  end

  it "due link dello stesso progetto non condividono l'indirizzo" do
    primo = described_class.call(project:, actor:).value
    secondo = described_class.call(project:, actor:).value

    expect(primo.slug).not_to eq(secondo.slug)
    expect(project.analytics_links.active).to contain_exactly(secondo)
  end

  it "l'autore viaggia col link: la domanda «chi è stato» ha una risposta" do
    expect(described_class.call(project:, actor:).value.created_by).to eq(actor)
  end

  it "senza autore il link nasce comunque: i link nati prima non ne hanno uno da inventare" do
    result = described_class.call(project:)

    expect(result).to be_ok
    expect(result.value.created_by).to be_nil
  end

  it "con la password il link resta protetto e la password non è leggibile" do
    link = described_class.call(project:, password: "segretissima", actor:).value

    expect(link).to be_password_protected
    expect(link.password_digest).not_to include("segretissima")
    expect(link.authenticate_password("segretissima")).to be_truthy
    expect(link.authenticate_password("altra")).to be(false)
  end

  it "una password vuota non conta come password" do
    expect(described_class.call(project:, password: "   ", actor:).value).not_to be_password_protected
  end

  it "se l'indirizzo non è salvabile risponde con un errore di dominio, non con un'eccezione" do
    esistente = described_class.call(project:, actor:).value
    allow(SecureRandom).to receive(:urlsafe_base64).and_return(esistente.slug)

    result = described_class.call(project: create(:project), actor:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-LINK-001")
    expect(result.error.details).to have_key(:slug)
  end
end
