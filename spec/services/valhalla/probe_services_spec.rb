# frozen_string_literal: true

require "rails_helper"

RSpec.describe Valhalla::ProbeServices, type: :service do
  include_context "valhalla service health cache"

  # ENV pulita per ogni esempio: la probe legge le stesse variabili dei client di dominio, e i valori
  # reali (vault in CI/dev) non devono trapelare nello snapshot né decidere il branch atteso qui.
  around do |example|
    keys = %w[AI_API_KEY EMBED_BASE_URL AI_BASE_URL CHAT_BASE_URL
              TELEGRAM_BOT_TOKEN GH_APP_ID GH_APP_PRIVATE_KEY]
    original = keys.index_with { |key| ENV[key] }
    keys.each { |key| ENV.delete(key) }
    # Il mittente email non passa da una ENV ma dalla chiave del client Resend: stessa igiene.
    original_api_key = Resend.api_key
    Resend.api_key = nil
    example.run
    original.each { |key, value| ENV[key] = value }
    Resend.api_key = original_api_key
  end

  def snapshot_for(key)
    Rails.cache.read(Valhalla::ProbeServices::CACHE_KEY).find { |entry| entry[:key] == key }
  end

  describe "servizio non configurato (ENV assenti)" do
    it "segna tutti i servizi come unconfigured senza fare alcuna richiesta HTTP" do
      described_class.call

      expect(WebMock).not_to have_requested(:get, /./)
      expect(WebMock).not_to have_requested(:post, /./)
      expect(%i[embedding telegram github email llm].map { |key| snapshot_for(key)[:status] })
        .to all(eq(:unconfigured))
    end
  end

  # CYRA-233: il mittente delle email stava su un dominio senza configurazione di spedizione e la cosa
  # non si vedeva da nessuna parte. Ora si vede qui, accanto agli altri servizi esterni.
  describe "email" do
    before { Resend.api_key = "re_test_key" }

    def stub_domains(*entries)
      stub_request(:get, "https://api.resend.com/domains")
        .to_return(status: 200, body: { data: entries }.to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "up quando il dominio del mittente è verificato, senza esporre la chiave nello snapshot" do
      stub_domains({ id: "d1", name: Mail::Address.new(ApplicationMailer.default[:from]).domain,
                     status: "verified" })

      described_class.call

      entry = snapshot_for(:email)
      expect(entry[:status]).to eq(:up)
      expect(entry.values.join).not_to include("re_test_key")
    end

    it "down quando il dominio del mittente non risulta configurato, col motivo in chiaro" do
      stub_domains({ id: "d1", name: "un-altro-dominio.test", status: "verified" })

      described_class.call

      entry = snapshot_for(:email)
      expect(entry[:status]).to eq(:down)
      expect(entry[:detail]).to eq("unknown_domain")
    end

    # Resta down anche dopo CYRA-771: nel fornitore che non risponde ci sta pure la chiave revocata,
    # che è quella con cui si spedisce. Il colore tranquillo è riservato al rifiuto esplicito.
    it "down quando il fornitore non risponde" do
      stub_request(:get, "https://api.resend.com/domains").to_timeout

      described_class.call

      expect(snapshot_for(:email)[:status]).to eq(:down)
      expect(snapshot_for(:email)[:detail]).to eq("error")
    end

    # Il guasto vero del ticket: la chiave di produzione spedisce ma non può leggere l'elenco domini,
    # e la scheda salute gridava alla posta giù mentre le email partivano.
    it "unverifiable quando la chiave è ristretta al solo invio, col motivo nello snapshot" do
      stub_request(:get, "https://api.resend.com/domains")
        .to_return(status: 401,
                   body: { statusCode: 401, name: "restricted_api_key",
                           message: "This API key is restricted to only send emails" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      described_class.call

      entry = snapshot_for(:email)
      expect(entry[:status]).to eq(:unverifiable)
      expect(entry[:detail]).to eq("restricted_key")
      expect(entry.values.join).not_to include("re_test_key")
    end
  end

  describe "embedding" do
    before do
      ENV["AI_API_KEY"] = "test-key"
      ENV["EMBED_BASE_URL"] = "https://embed.test/v1"
    end

    let(:embed_url) { "https://embed.test/v1/embeddings" }
    let(:vector) { Array.new(Ai::Constants::EMBEDDING_DIMENSIONS, 0.1) }

    it "up quando un embedding vero con chiave e alias di produzione torna della dimensione giusta" do
      post = stub_request(:post, embed_url)
             .with(headers: { "Authorization" => "Bearer test-key" },
                   body: hash_including("model" => Ai::Constants::EMBEDDING_MODEL))
             .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => vector } ] }.to_json)

      described_class.call

      entry = snapshot_for(:embedding)
      expect(entry[:status]).to eq(:up)
      expect(entry.values.join).not_to include("test-key")
      expect(post).to have_been_requested
    end

    it "down quando l'upstream risponde errore (chiave revocata, alias rinominato)" do
      stub_request(:post, embed_url).to_return(status: 401, body: "{}")
      described_class.call
      expect(snapshot_for(:embedding)[:status]).to eq(:down)
    end

    it "down quando il vettore non ha la dimensione della colonna: modello sbagliato dietro l'alias" do
      stub_request(:post, embed_url)
        .to_return(status: 200, body: { "data" => [ { "index" => 0, "embedding" => [ 0.1, 0.2 ] } ] }.to_json)
      described_class.call
      expect(snapshot_for(:embedding)[:status]).to eq(:down)
    end

    it "down su timeout, con detail diagnostico (mai un ENV)" do
      stub_request(:post, embed_url).to_timeout
      described_class.call
      entry = snapshot_for(:embedding)
      expect(entry[:status]).to eq(:down)
      expect(entry[:detail]).to be_present
    end
  end

  # CYRA-765 — l'AI generativa la offre il sistema: torna una chiave sola da sondare, e la sonda è
  # una generazione VERA. Un `/models` verde lascerebbe la card «Attivo» con vLLM giù dietro LiteLLM.
  describe "llm" do
    let(:llm_url) { "https://llm.test/v1/chat/completions" }

    before do
      ENV["AI_API_KEY"] = "test-ai-key"
      ENV["AI_BASE_URL"] = "https://llm.test/v1"
    end

    it "up quando il modello risponde con del testo" do
      stub_request(:post, llm_url)
        .to_return(status: 200, body: { "choices" => [ { "message" => { "content" => "pong" } } ] }.to_json)

      described_class.call

      expect(snapshot_for(:llm)[:status]).to eq(:up)
    end

    it "chiede il modello di produzione con un tetto di token minimo, e la chiave non finisce nello snapshot" do
      stub_request(:post, llm_url)
        .to_return(status: 200, body: { "choices" => [ { "message" => { "content" => "pong" } } ] }.to_json)

      described_class.call

      expect(WebMock).to have_requested(:post, llm_url)
        .with(headers: { "Authorization" => "Bearer test-ai-key" },
              body: hash_including("model" => Ai::Llm::Constants::MODEL, "max_tokens" => 8))
      expect(snapshot_for(:llm).values.join).not_to include("test-ai-key")
    end

    it "down quando il server risponde 503" do
      stub_request(:post, llm_url).to_return(status: 503, body: "")

      described_class.call

      expect(snapshot_for(:llm)[:status]).to eq(:down)
    end

    # Il caso vero del passaggio al server di casa: 200 e nessun testo (modello che spende il budget
    # a ragionare, o filtro). Verde qui vorrebbe dire card «Attivo» con l'assistente muto.
    it "down quando risponde 200 ma senza testo" do
      stub_request(:post, llm_url)
        .to_return(status: 200, body: { "choices" => [ { "message" => { "content" => "" } } ] }.to_json)

      described_class.call

      expect(snapshot_for(:llm)[:status]).to eq(:down)
    end

    it "down su timeout, con detail diagnostico (mai un ENV)" do
      stub_request(:post, llm_url).to_timeout

      described_class.call

      entry = snapshot_for(:llm)
      expect(entry[:status]).to eq(:down)
      expect(entry[:detail]).to be_present
      expect(entry[:detail]).not_to include("test-ai-key")
    end

    it "senza chiave non chiama nessuno: non configurato" do
      ENV.delete("AI_API_KEY")

      described_class.call

      expect(WebMock).not_to have_requested(:post, llm_url)
      expect(snapshot_for(:llm)[:status]).to eq(:unconfigured)
    end
  end

  describe "telegram" do
    before { ENV["TELEGRAM_BOT_TOKEN"] = "test-token" }

    it "up quando getMe risponde ok:true" do
      stub_request(:get, "https://api.telegram.org/bottest-token/getMe")
        .to_return(status: 200, body: { ok: true }.to_json)
      described_class.call
      expect(snapshot_for(:telegram)[:status]).to eq(:up)
    end

    it "down quando getMe risponde ok:false" do
      stub_request(:get, "https://api.telegram.org/bottest-token/getMe")
        .to_return(status: 200, body: { ok: false }.to_json)
      described_class.call
      expect(snapshot_for(:telegram)[:status]).to eq(:down)
    end
  end

  describe "github" do
    before do
      ENV["GH_APP_ID"] = "123"
      ENV["GH_APP_PRIVATE_KEY"] = "fake-key"
    end

    it "up quando /meta risponde 200 (nessun JWT/installation coinvolto)" do
      stub_request(:get, "https://api.github.com/meta").to_return(status: 200, body: "{}")
      described_class.call
      expect(snapshot_for(:github)[:status]).to eq(:up)
    end

    it "down quando /meta non risponde 200" do
      stub_request(:get, "https://api.github.com/meta").to_return(status: 500)
      described_class.call
      expect(snapshot_for(:github)[:status]).to eq(:down)
    end
  end


  it "scrive uno snapshot con checked_at per ciascun servizio" do
    described_class.call
    snapshot = Rails.cache.read(Valhalla::ProbeServices::CACHE_KEY)
    expect(snapshot.map { |entry| entry[:checked_at] }).to all(be_a(ActiveSupport::TimeWithZone).or(be_a(Time)))
  end

  # CYRA-764 — la sonda del revisore chiede un token vero al modello, con chiave e alias di
  # produzione: `/models` direbbe solo che l'alias esiste.
  describe "revisore knowledge (chat)" do
    let(:url) { "https://ai.test/v1/chat/completions" }

    before do
      ENV["AI_API_KEY"] = "chat-key"
      ENV["CHAT_BASE_URL"] = "https://ai.test/v1"
    end

    it "up quando il modello risponde con una scelta, senza esporre la chiave nello snapshot" do
      post = stub_request(:post, url)
             .with(headers: { "Authorization" => "Bearer chat-key" }) { |req|
               body = JSON.parse(req.body)
               body["model"] == Ai::Llm::Constants::MODEL && body["stream"] == false && body["max_tokens"] == 1 &&
                 body.dig("chat_template_kwargs", "enable_thinking") == false
             }
             .to_return(status: 200, body: { choices: [ { message: { content: "ok" } } ] }.to_json)

      described_class.call

      expect(snapshot_for(:chat)[:status]).to eq(:up)
      expect(post).to have_been_requested
      expect(snapshot_for(:chat).to_s).not_to include("chat-key")
    end

    it "down quando il proxy rifiuta (chiave revocata, alias rinominato)" do
      stub_request(:post, url).to_return(status: 400, body: { error: { message: "Invalid model name" } }.to_json)
      described_class.call
      expect(snapshot_for(:chat)[:status]).to eq(:down)
    end

    it "down su timeout, con detail diagnostico" do
      stub_request(:post, url).to_timeout
      described_class.call
      expect(snapshot_for(:chat)[:status]).to eq(:down)
      expect(snapshot_for(:chat)[:detail]).to be_present
    end
  end

  # CYRA-914 P10: the country lookup degrades in silence when the file is missing, so its state shows here.
  describe "geo database" do
    let(:dir) { Dir.mktmpdir }
    let(:path) { File.join(dir, "GeoLite2-Country.mmdb") }

    before { stub_const("Analytics::Constants::GEOIP_DB_PATH", path) }
    after { FileUtils.remove_entry(dir) }

    it "is unconfigured without a license key and without a file" do
      described_class.call

      expect(snapshot_for(:geoip)[:status]).to eq(:unconfigured)
    end

    it "is up with a recent file" do
      File.binwrite(path, "mmdb")
      described_class.call

      expect(snapshot_for(:geoip)[:status]).to eq(:up)
    end

    it "is down with a file older than two weeks" do
      File.binwrite(path, "mmdb")
      FileUtils.touch(path, mtime: 15.days.ago.to_time)
      described_class.call

      expect(snapshot_for(:geoip)).to include(status: :down, detail: "stale")
    end
  end
end
