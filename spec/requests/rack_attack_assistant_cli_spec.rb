# frozen_string_literal: true

require "rails_helper"

# CYRA-527: prima di questi throttle /cli/v1 non aveva alcun freno di velocità, e l'assistente è il
# solo endpoint del prodotto in cui UNA richiesta HTTP può costare come decine — ogni domanda spende
# più chiamate al modello, più la ricerca semantica. Un client entrato in ciclo era un rubinetto
# aperto sui costi.
#
# Il conteggio sta sul TOKEN e non sull'indirizzo IP (Definition of Done): il client è una CLI o
# un'app, che in mobilità cambia indirizzo di continuo e in rete mobile lo condivide con altri. Per IP
# il limite sarebbe insieme aggirabile (basta cambiare rete) e ingiusto (due utenti dietro lo stesso
# NAT si ruberebbero la quota).
#
# rack-attack è disattivato in tutta la suite e conta su un null_store (spec/support/rack_attack.rb):
# gli esempi che verificano il freno DAVVERO in funzione lo riabilitano con un MemoryStore, gli altri
# invocano direttamente il block del throttle (come rack_attack_ingest_spec / _share_analytics_spec).
RSpec.describe "Rack::Attack — assistente da CLI", type: :request do
  let(:write_throttle) { Rack::Attack.throttles.fetch("assistant_cli/token") }
  let(:read_throttle) { Rack::Attack.throttles.fetch("assistant_cli_read/token") }

  let(:token) { "cyi_u_unsegretoqualsiasi" }
  let(:conversation_id) { "5b1f0c5e-0000-4000-8000-000000000001" }
  let(:message_path) { "/cli/v1/assistant/conversations/#{conversation_id}/messages" }

  def attack_request(path, method: "GET", bearer: token, ip: "203.0.113.7")
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip)
    env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}" if bearer
    Rack::Attack::Request.new(env)
  end

  describe "la chiave del conteggio" do
    it "è il digest del token, mai il segreto in chiaro (la chiave finisce in cache e nei log)" do
      key = write_throttle.block.call(attack_request(message_path, method: "POST"))

      expect(key).to be_present
      expect(key).not_to include(token)
      expect(key).to match(/\A[0-9a-f]+\z/)
    end

    # Nemmeno il digest INTERO: è il valore con cui il DB riconosce il token, e la riga di log del
    # throttle scattato finisce nel monitoring. Un troncamento basta a distinguere i token.
    it "non è nemmeno il digest intero con cui il token viene riconosciuto" do
      key = write_throttle.block.call(attack_request(message_path, method: "POST"))

      expect(key).not_to eq(Digest::SHA256.hexdigest(token))
      expect(Digest::SHA256.hexdigest(token)).to start_with(key)
    end

    # Scenario 2 del ticket, sul lato della chiave: l'indirizzo non entra nel conteggio.
    it "è la stessa da due indirizzi diversi" do
      da_casa = write_throttle.block.call(attack_request(message_path, method: "POST", ip: "203.0.113.1"))
      da_fuori = write_throttle.block.call(attack_request(message_path, method: "POST", ip: "198.51.100.9"))

      expect(da_fuori).to eq(da_casa)
    end

    # Scenario 3 del ticket, sul lato della chiave: due token non condividono il contatore.
    it "è diversa per due token diversi" do
      primo = write_throttle.block.call(attack_request(message_path, method: "POST"))
      secondo = write_throttle.block.call(attack_request(message_path, method: "POST", bearer: "cyi_u_unaltro"))

      expect(secondo).not_to eq(primo)
    end

    it "non matcha senza token, né con uno schema diverso da Bearer: lì risponde l'autenticazione" do
      senza = attack_request(message_path, method: "POST", bearer: nil)
      basic = Rack::Attack::Request.new(
        Rack::MockRequest.env_for(message_path, method: "POST").merge("HTTP_AUTHORIZATION" => "Basic abc")
      )

      expect(write_throttle.block.call(senza)).to be_nil
      expect(write_throttle.block.call(basic)).to be_nil
    end

    it "non matcha con un Bearer vuoto" do
      expect(write_throttle.block.call(attack_request(message_path, method: "POST", bearer: "   "))).to be_nil
    end
  end

  describe "throttle assistant_cli/token (le domande all'AI)" do
    it "matcha l'invio di una domanda" do
      expect(write_throttle.block.call(attack_request(message_path, method: "POST"))).to be_present
    end

    # Le rotte instradano ANCHE con estensione di formato: senza coprirla, aggiungere `.json`
    # all'indirizzo aggirava il limite e l'abuso non lasciava traccia (stesso vettore di CYRA-251).
    it "matcha anche con l'estensione di formato e col trailing slash" do
      expect(write_throttle.block.call(attack_request("#{message_path}.json", method: "POST"))).to be_present
      expect(write_throttle.block.call(attack_request("#{message_path}/", method: "POST"))).to be_present
    end

    it "matcha l'apertura di una conversazione (scrittura, ma della stessa famiglia)" do
      expect(write_throttle.block.call(attack_request("/cli/v1/assistant/conversations", method: "POST"))).to be_present
    end

    it "matcha la cancellazione di una conversazione" do
      path = "/cli/v1/assistant/conversations/#{conversation_id}"

      expect(write_throttle.block.call(attack_request(path, method: "DELETE"))).to be_present
    end

    # "Chiedi ai ticket" e "chiedi alla knowledge base" spendono la stessa moneta dell'assistente
    # (chiamate al modello più ricerca semantica) e dalla CLI erano senza freno esattamente come lui.
    it "matcha i due «chiedi» che pure interrogano l'AI" do
      expect(write_throttle.block.call(attack_request("/cli/v1/tickets/ask", method: "POST"))).to be_present
      expect(write_throttle.block.call(attack_request("/cli/v1/knowledge/ask.json", method: "POST"))).to be_present
    end

    it "NON matcha le letture (hanno un tetto loro, molto più largo)" do
      expect(write_throttle.block.call(attack_request(message_path))).to be_nil
    end

    it "NON matcha gli altri endpoint della CLI" do
      expect(write_throttle.block.call(attack_request("/cli/v1/tickets", method: "POST"))).to be_nil
      expect(write_throttle.block.call(attack_request("/cli/v1/knowledge/pages", method: "POST"))).to be_nil
    end

    it "NON matcha l'assistente del sito (coperto dal throttle per IP della sessione web)" do
      path = "/member/assistant/conversations"

      expect(write_throttle.block.call(attack_request(path, method: "POST"))).to be_nil
    end

    # Venti domande al minuto sono molto sopra una conversazione umana (una ogni tre secondi,
    # sostenuta) e tagliano netto un client entrato in ciclo.
    it "lascia venti domande al minuto" do
      expect(write_throttle.limit).to eq(20)
      expect(write_throttle.period).to eq(60)
    end
  end

  describe "throttle assistant_cli_read/token (storia e attesa della risposta)" do
    it "matcha l'interrogazione dello stato di una risposta" do
      path = "/cli/v1/assistant/messages/#{conversation_id}"

      expect(read_throttle.block.call(attack_request(path))).to be_present
    end

    it "matcha l'elenco delle conversazioni" do
      expect(read_throttle.block.call(attack_request("/cli/v1/assistant/conversations"))).to be_present
    end

    it "matcha l'attesa dell'esito di una richiesta AI asincrona" do
      path = "/cli/v1/ai/requests/#{conversation_id}"

      expect(read_throttle.block.call(attack_request(path))).to be_present
    end

    it "NON matcha le scritture (contate a parte, molto più stretto)" do
      expect(read_throttle.block.call(attack_request(message_path, method: "POST"))).to be_nil
    end

    # L'app interroga lo stato circa una volta al secondo mentre aspetta: un tetto stretto qui
    # strozzerebbe l'attesa legittima invece dell'abuso.
    it "è largo abbastanza da non strozzare l'attesa della risposta" do
      expect(read_throttle.limit).to eq(300)
      expect(read_throttle.period).to eq(60)
    end
  end

  # Gli scenari del ticket con richieste VERE: qui rack-attack è accesso e i contatori avanzano
  # davvero, così si vede la risposta che riceve il client e cosa NON arriva all'AI.
  describe "il freno in funzione" do
    # Il tempo va fermato per tutta la durata dell'esempio. Il contatore di rack-attack vive in una
    # finestra discreta di un minuto: 20 richieste piu' quella di prova, su una macchina carica,
    # possono cadere a cavallo del cambio di minuto — e al minuto nuovo il contatore riparte da zero,
    # quindi la richiesta che doveva essere fermata passa. Verde sul portatile, rossa sui server
    # della build, e senza dire perche': l'esempio fallisce sull'asserzione giusta per il motivo
    # sbagliato. Fermando il tempo la finestra e' una sola per costruzione.
    around do |example|
      original_store = Rack::Attack.cache.store
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      Rack::Attack.enabled = true
      freeze_time { example.run }
    ensure
      Rack::Attack.enabled = false
      Rack::Attack.cache.store = original_store
    end

    let(:account) { create(:account) }
    let(:organization) { create(:organization) }
    let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
    let(:conversation) { Assistant::Conversation.create!(account:, organization:, kind: :tools) }

    # Il secondo token vive in un'altra organizzazione: in una organizzazione l'owner è uno solo.
    let(:altro_secret) do
      altro_account = create(:account)
      altra_organization = create(:organization)
      create(:membership, account: altro_account, organization: altra_organization, role: :owner)
      Accounts::ApiTokens::Issue.call(account: altro_account, organization: altra_organization,
                                      name: "CLI").value[:secret]
    end

    before do
      create(:membership, account:, organization:, role: :owner)
      # L'assistente gira con la chiave dell'organizzazione (CYRA-547).
      create(:integration_credential, organization:)
    end

    def ask(bearer: secret, ip: "203.0.113.7")
      post "/cli/v1/assistant/conversations/#{conversation.id}/messages",
           params: { text: "che progetti ho?" },
           headers: { "Authorization" => "Bearer #{bearer}" },
           env: { "REMOTE_ADDR" => ip }
    end

    def open_conversation(bearer: secret, ip: "203.0.113.7")
      post "/cli/v1/assistant/conversations",
           headers: { "Authorization" => "Bearer #{bearer}" },
           env: { "REMOTE_ADDR" => ip }
    end

    # Portare il contatore al limite significa ripetere la STESSA richiesta: le query per-richiesta
    # (risoluzione del token, gate, perimetro visibile) si ripetono legittimamente e non sono un N+1
    # di produzione — il guard va messo in pausa solo sul riempimento, non sulla richiesta in esame.
    def burn_quota!(&fill)
      allow_n_plus_one(&fill)
    end

    # Scenario 1: oltre il limite la chiamata viene fermata, e all'AI non arriva nulla.
    it "oltre il limite risponde R429-SYSTEM-001 e non inoltra la domanda all'AI" do
      burn_quota! { write_throttle.limit.times { ask } }
      expect(response).to have_http_status(:accepted) # fino al limite le domande passano

      expect { ask }.not_to have_enqueued_job(Assistant::ConverseJob)

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.dig("error", "code")).to eq("R429-SYSTEM-001")
      expect(response.headers["Retry-After"]).to be_present
    end

    # Scenario 2: il conteggio segue il token, non l'indirizzo.
    it "non azzera il conteggio quando l'indirizzo cambia" do
      meta = write_throttle.limit / 2
      burn_quota! do
        meta.times { open_conversation(ip: "203.0.113.1") }
        (write_throttle.limit - meta).times { open_conversation(ip: "198.51.100.9") }
      end

      ask(ip: "192.0.2.4")

      expect(response).to have_http_status(:too_many_requests)
      expect(Assistant::Message.count).to be_zero # la domanda non è nemmeno stata scritta
    end

    # Scenario 3: due token diversi non si rubano il credito.
    it "lascia passare un secondo token quando il primo ha esaurito il suo limite" do
      secondo_token = nil
      burn_quota! do
        secondo_token = altro_secret
        write_throttle.limit.times { ask }
        ask
      end
      expect(response).to have_http_status(:too_many_requests) # il primo token ha finito la quota

      open_conversation(bearer: secondo_token)

      expect(response).to have_http_status(:created)
    end
  end
end
