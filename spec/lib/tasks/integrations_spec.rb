# frozen_string_literal: true

require "rails_helper"
require "rake"

# CYRA-549 — il comando che esegue il passaggio a mano, quando l'organizzazione dell'operatore non è
# riconoscibile da sola. Una migrazione si esegue una volta sola: senza questo comando, capire più
# tardi quale fosse l'organizzazione giusta non servirebbe a niente.
RSpec.describe "bin/rails integrations:adopt_system_keys", :silence_output do
  let(:task_name) { "integrations:adopt_system_keys" }

  before do
    load Rails.root.join("lib/tasks/integrations.rake").to_s unless Rake::Task.task_defined?(task_name)
  end

  around do |example|
    originale = ENV["GOOGLE_PAGESPEED_API_KEY"]
    ENV["GOOGLE_PAGESPEED_API_KEY"] = "AIza-di-sistema"
    example.run
    ENV["GOOGLE_PAGESPEED_API_KEY"] = originale
  end

  # `execute` e non `invoke`: qui l'ambiente Rails è già caricato dalle prove, e `invoke` cercherebbe
  # di costruire la dipendenza `environment`, che in questo contesto non esiste.
  def esegui(argomento = nil)
    Rake::Task[task_name].execute(Rake::TaskArguments.new([ :organization ], [ argomento ]))
  end

  it "esiste" do
    expect(Rake::Task.task_defined?(task_name)).to be(true)
  end

  it "adotta le chiavi sull'organizzazione indicata per nome" do
    organizzazione = create(:organization, slug: "acme")

    expect { esegui("acme") }.to output(/acme/).to_stdout

    expect(Integrations::Credential.find_by(organization: organizzazione, provider: "pagespeed").api_key)
      .to eq("AIza-di-sistema")
  end

  it "non tocca nessun'altra organizzazione" do
    create(:organization, slug: "acme")
    altra = create(:organization, slug: "altra")

    esegui("acme")

    expect(Integrations::Credential.where(organization: altra)).to be_empty
  end

  # Uno slug scritto storto arriva su una colonna di tipo identificativo: senza il controllo di forma
  # il database solleverebbe, e chi ha sbagliato a scrivere leggerebbe una riga di errore invece di
  # «non trovata».
  it "un nome che non esiste si ferma e lo dice, senza errori del database" do
    expect { esegui("non-esiste") }.to raise_error(SystemExit).and output(/non trovata/).to_stderr
  end

  it "senza argomento sceglie l'organizzazione di chi gestisce l'installazione" do
    operatore = create(:organization)
    create(:membership, organization: operatore, account: create(:account, god: true), role: :owner)

    esegui

    expect(Integrations::Credential.where(organization: operatore).pluck(:provider)).to include("pagespeed")
  end

  it "rilanciarlo non duplica niente" do
    create(:organization, slug: "acme")
    esegui("acme")

    expect { esegui("acme") }.not_to change(Integrations::Credential, :count)
  end
end
