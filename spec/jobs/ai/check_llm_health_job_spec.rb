# frozen_string_literal: true

require "rails_helper"
require "yaml"

# CYRA-765 · L'AI generativa ora la offre il sistema con un server di casa: se quello non risponde,
# assistente, smistamento, bozze e doppioni si spengono in silenzio — nessun errore a schermo,
# nessun avviso. Con Gemini si provava la chiave di ogni organizzazione; qui la chiave è una e la
# prova è una generazione vera, minima, sulla stessa porta delle feature.
RSpec.describe Ai::CheckLlmHealthJob do
  let!(:organization) { create(:organization) }
  # CYRA-875: the alert goes to the gods' organization only.
  let!(:god) { create(:account, god: true).tap { |a| create(:membership, account: a, organization: organization) } }
  let(:client) { instance_double(Ai::Llm::Client) }
  # In test l'app usa :null_store (ogni read → nil): il ricordo del guasto, che è tutta la logica
  # «era giù → annuncia il rientro», non sopravviverebbe. Stesso pattern di
  # spec/support/valhalla_service_health_cache.rb.
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    allow(Ai::Llm::Client).to receive(:new).and_return(client)
  end

  it "non fa niente se il god ha spento tutte le funzioni generative" do
    allow(Ai::Feature).to receive(:generative_disabled?).and_return(true)

    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
    expect(Ai::Llm::Client).not_to have_received(:new)
  end

  it "server su e mai giù prima: nessun avviso" do
    allow(client).to receive(:generate_content).and_return("pong")

    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "server down: one ai_unavailable alert to the god's organization, none to customers (CYRA-875)" do
    customer = create(:organization)
    allow(client).to receive(:generate_content)
      .and_raise(Ai::Llm::Client::Error.new("giù", code: "R503-LLM-001", status: :service_unavailable))

    expect { described_class.perform_now }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "ai_unavailable", organization_id: organization.id,
                           subject_type: "Organizations::Organization", subject_id: organization.id,
                           value: "R503-LLM-001"))
    expect(Rails.cache.read(described_class::DOWN_KEY)).to be(true)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:args].first["organization_id"] })
      .not_to include(customer.id)
  end

  it "server tornato su dopo un giù: annuncia ai_available e dimentica il guasto" do
    Rails.cache.write(described_class::DOWN_KEY, true)
    allow(client).to receive(:generate_content).and_return("pong")

    expect { described_class.perform_now }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "ai_available", organization_id: organization.id))
    expect(Rails.cache.read(described_class::DOWN_KEY)).to be_nil
  end

  it "chiave mancante conta come giù, con codice di configurazione" do
    allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError)

    expect { described_class.perform_now }
      .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "ai_unavailable",
                                                                      value: "R502-LLM-002"))
  end

  # Il controllo gira ogni quarto d'ora: se avvisasse solo alla prima caduta, un avviso perso
  # (canale giù, regola creata dopo) resterebbe perso per sempre. Il rumore lo governa il throttle
  # della regola, come per agents_host_stale.
  it "continua ad avvisare finché resta giù" do
    allow(client).to receive(:generate_content)
      .and_raise(Ai::Llm::Client::Error.new("giù", code: "R503-LLM-001", status: :service_unavailable))
    described_class.perform_now

    expect { described_class.perform_now }
      .to have_enqueued_job(Alerting::EvaluateJob).with(hash_including(event_type: "ai_unavailable"))
  end

  it "il rientro parte UNA volta sola: al giro dopo va tutto bene e non è una notizia" do
    Rails.cache.write(described_class::DOWN_KEY, true)
    allow(client).to receive(:generate_content).and_return("pong")
    described_class.perform_now

    expect { described_class.perform_now }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "logga il motivo: il degrado silenzioso deve lasciare una traccia anche nei log" do
    allow(Rails.logger).to receive(:error)
    allow(client).to receive(:generate_content)
      .and_raise(Ai::Llm::Client::Error.new("giù", code: "R503-LLM-001", status: :service_unavailable))

    described_class.perform_now

    expect(Rails.logger).to have_received(:error).with(a_string_including("R503-LLM-001"))
  end

  # «Entro quindici minuti» è una promessa che mantiene la pianificazione, non il codice del job:
  # senza questa riga in recurring.yml il controllo resta un file che non gira mai.
  describe "è appeso al giro dei quindici minuti" do
    let(:voce) do
      YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")
          .values.find { |task| task["class"] == described_class.name }
    end

    it "compare fra i ricorrenti di produzione, sulla corsia della manutenzione" do
      expect(voce).to be_present
      expect(voce["queue"]).to eq("maintenance")
    end

    it "gira almeno ogni quindici minuti" do
      expect(voce["schedule"]).to match(/every 15 minutes/)
    end
  end
end
