# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Valhalla
  # Sonda i servizi esterni collegati (embedding, Telegram, GitHub, mittente email) con timeout CORTI
  # e scrive lo snapshot in Solid Cache — mai chiamato a request-time (bloccherebbe Puma fino a 4x i
  # timeout e martellerebbe gli upstream a ogni load della pagina /valhalla/health). Chiamato dal
  # ricorrente Valhalla::ProbeServicesJob.
  #
  # Legge le stesse ENV dei client di dominio (Ai::Embedding::Client, Telegram::Send, Github::Client)
  # ma non li usa: le probe sono dirette, leggere, con i timeout di QUESTA classe, e non passano MAI
  # dai client di dominio. Lo snapshot scritto porta solo lo STATO derivato, mai un valore ENV.
  #
  # Una domanda sola per tutti: «risponde?». Fino a CYRA-765 il generativo faceva eccezione, perché
  # ogni organizzazione lo collegava con le PROPRIE credenziali e si contavano le chiavi rotte
  # invece di sondare; ora l'AI la offre il sistema con una chiave sua, e anche lì si sonda.
  class ProbeServices < ApplicationService
    CACHE_KEY = "valhalla:service_health"

    OPEN_TIMEOUT_SECONDS = 3
    READ_TIMEOUT_SECONDS = 5

    def call
      checked_at = Time.current
      snapshot = [
        probe_embedding(checked_at),
        probe_chat(checked_at),
        probe_telegram(checked_at),
        probe_github(checked_at),
        probe_email(checked_at),
        probe_llm(checked_at),
        probe_geoip(checked_at)
      ]
      Rails.cache.write(CACHE_KEY, snapshot)
      Result.ok(snapshot)
    end

    private

    # Un embedding VERO, minimo, con la chiave e l'alias di produzione (CYRA-758). Il proxy LiteLLM
    # ha un `/health/liveliness` senza auth, ma dice solo che il proxy è vivo: una chiave revocata o
    # un alias rinominato lo lasciano verde mentre ogni funzione semantica degrada in silenzio, e la
    # card «Attivo» diventerebbe una bugia. La risposta deve avere un vettore della dimensione della
    # colonna pgvector: un modello sbagliato risponde 200 con la dimensione sbagliata.
    # Il path si appende alla base (che include `/v1`): URI.join con path assoluto lo perderebbe.
    def probe_embedding(checked_at)
      config = Ai::Configuration.current
      api_key = config.api_key
      base_url = config.embed_base_url
      return unconfigured(:embedding, checked_at) unless config.embeddings_configured?

      probe(:embedding, checked_at) do
        response = post(URI.parse("#{base_url.chomp('/')}/embeddings"),
                        body: { model: config.embedding_model, input: [ "healthcheck" ] },
                        headers: { "Authorization" => "Bearer #{api_key}" })
        next false unless response.code.to_i.between?(200, 299)

        vector = JSON.parse(response.body).dig("data", 0, "embedding")
        vector.is_a?(Array) && vector.length == Ai::Configuration.current.embedding_dimensions
      end
    end

    # Un token VERO dal modello del revisore (CYRA-764), con la chiave e l'alias di produzione. Resta
    # una sonda A PARTE anche dopo l'unificazione del client (CYRA-766): l'alias è lo stesso, la
    # CHIAVE no, e sono le due chiavi a spegnersi separatamente — con una sola sonda un revisore senza
    # chiave resterebbe verde finché l'assistente funziona.
    # `/models` direbbe solo che l'alias esiste, non che vLLM risponde. Senza stream e con un token
    # solo la risposta sta nel read timeout della sonda. Il ragionamento va spento anche qui, o il
    # modello spende il token a pensare e risponde vuoto.
    def probe_chat(checked_at)
      config = Ai::Configuration.current
      api_key = config.api_key
      base_url = config.review_base_url
      return unconfigured(:chat, checked_at) unless config.review_configured?

      probe(:chat, checked_at) do
        response = post(URI.parse("#{base_url.chomp('/')}/chat/completions"),
                        body: chat_probe_body(config, "ok", 1).merge(stream: false),
                        headers: { "Authorization" => "Bearer #{api_key}" })
        next false unless response.code.to_i.between?(200, 299)

        JSON.parse(response.body).dig("choices", 0).present?
      end
    end
    # getMe: endpoint leggero della Bot API, valida che il token sia accettato.
    def probe_telegram(checked_at)
      token = Settings::Integrations.value(:telegram_bot_token)
      return unconfigured(:telegram, checked_at) if token.blank?

      probe(:telegram, checked_at) do
        response = get(URI.parse("https://api.telegram.org/bot#{token}/getMe"))
        response.code.to_i == 200 && JSON.parse(response.body)["ok"] == true
      end
    end

    # /meta è pubblico e non richiede auth: verifica solo la raggiungibilità dell'API GitHub, non le
    # credenziali della App (coerente con "unconfigured" = App non impostata più sotto).
    def probe_github(checked_at)
      app_id = Settings::Integrations.value(:gh_app_id)
      private_key = Settings::Integrations.value(:gh_app_private_key)
      return unconfigured(:github, checked_at) if app_id.blank? || private_key.blank?

      probe(:github, checked_at) do
        get(URI.parse("https://api.github.com/meta")).code.to_i == 200
      end
    end

    # Unico servizio la cui probe NON è una GET diretta: qui non interessa che il fornitore risponda, ma
    # che il MITTENTE sia abilitato a spedire — un account Resend perfettamente raggiungibile con un
    # dominio non verificato non manda una sola email (CYRA-233). La domanda vive in Ops::MailSenderCheck,
    # che è anche il controllo giornaliero: un posto solo, stessa risposta in pagina e nei log.
    # `detail` porta lo stato preciso (unknown_domain/unverified/invalid_sender/error/restricted_key),
    # mai un segreto.
    #
    # Tre esiti, non due (CYRA-771): fra «spedisce» e «non spedisce» c'è «non lo so», ed è la
    # condizione normale in produzione — la chiave è abilitata al solo invio e il fornitore rifiuta
    # la lettura dell'elenco domini, mentre le email partono. Dipingere di rosso un mittente che non
    # abbiamo potuto guardare insegna a ignorare il rosso quando conta.
    #
    # «Non lo so» è SOLO il rifiuto esplicito (Result#unverifiable?, cioè :restricted_key): il
    # fornitore che non risponde resta :down, perché in quel cesto ci sta anche la chiave revocata,
    # che ferma la spedizione per davvero.
    def probe_email(checked_at)
      result = Ops::MailSenderCheck.call
      return unconfigured(:email, checked_at) if result.status == :unconfigured

      { key: :email, status: email_status(result), checked_at:,
        detail: result.deliverable? ? nil : result.status.to_s }
    end

    def email_status(result)
      return :up if result.deliverable?
      return :unverifiable if result.unverifiable?

      :down
    end

    # Il server AI di casa (CYRA-765), che alimenta assistente, smistamento, bozze e doppioni: una
    # generazione VERA e minima con la chiave di sistema e i timeout corti di QUESTA classe. Come per
    # l'embedding, un `/health/liveliness` o un `/models` verde non basta — vLLM può essere giù
    # dietro LiteLLM, e la card «Attivo» sarebbe una bugia. Il testo deve arrivare davvero: un
    # modello che risponde a vuoto è un guasto quanto uno che non risponde.
    # Il path si appende alla base (che include `/v1`): URI.join con path assoluto lo perderebbe.
    def probe_llm(checked_at)
      config = Ai::Configuration.current
      api_key = config.api_key
      base_url = config.chat_base_url
      return unconfigured(:llm, checked_at) unless config.chat_configured?

      probe(:llm, checked_at) do
        response = post(URI.parse("#{base_url.chomp('/')}/chat/completions"),
                        body: chat_probe_body(config, "ping", 8),
                        headers: { "Authorization" => "Bearer #{api_key}" })
        next false unless response.code.to_i.between?(200, 299)

        JSON.parse(response.body).dig("choices", 0, "message", "content").to_s.present?
      end
    end

    # vLLM's thinking switch goes only to our gateway: other providers reject unknown fields.
    def chat_probe_body(config, text, max_tokens)
      body = { model: config.chat_model, max_tokens:, messages: [ { role: "user", content: text } ] }
      body[:chat_template_kwargs] = { enable_thinking: false } if Ai::Llm::Client.vllm_extras?
      body
    end

    # No network: the country lookup reads a local file and degrades in silence without it (CYRA-914 P10).
    GEOIP_STALE_AFTER = 14.days

    def probe_geoip(checked_at)
      path = Analytics::Constants::GEOIP_DB_PATH
      unless File.exist?(path)
        return unconfigured(:geoip, checked_at) if ENV["MAXMIND_LICENSE_KEY"].blank?

        return { key: :geoip, status: :down, checked_at:, detail: "missing" }
      end
      return { key: :geoip, status: :down, checked_at:, detail: "stale" } if File.mtime(path) < GEOIP_STALE_AFTER.ago

      { key: :geoip, status: :up, checked_at:, detail: nil }
    end

    def probe(key, checked_at)
      up = yield
      { key:, status: up ? :up : :down, checked_at:, detail: nil }
    rescue StandardError => e
      { key:, status: :down, checked_at:, detail: e.class.name.demodulize }
    end

    def unconfigured(key, checked_at)
      { key:, status: :unconfigured, checked_at:, detail: nil }
    end

    def get(uri, headers: {})
      request(Net::HTTP::Get.new(uri), uri, headers)
    end

    # JSON in POST: tornata con la sonda embedding (CYRA-758), che deve chiedere un vettore vero.
    def post(uri, body:, headers: {})
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req.body = body.to_json
      request(req, uri, headers)
    end

    # Unico punto che conosce TLS e timeout: nessuna sonda deve poter divergere sulle attese.
    def request(req, uri, headers)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      headers.each { |name, value| req[name] = value }
      http.request(req)
    end
  end
end
