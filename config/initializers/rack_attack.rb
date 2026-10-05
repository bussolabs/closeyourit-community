# frozen_string_literal: true

# Rate limiting + blocklist sonde su file sensibili. Vedi rules/rails/security.md.
class Rack::Attack
  throttle("coworkers_worker/ip", limit: 900, period: 1.minute) do |request|
    request.ip if request.path.start_with?("/api/v1/coworkers/")
  end

  # Blocklist path sensibili — risponde 404 per non rivelare che stiamo bloccando.
  SENSITIVE_PATHS = %w[
    /.env
    /.git /.svn /.hg /.ssh
    /.aws /.vscode/sftp.json /.idea /.DS_Store
    /config/master.key /config/secrets.yml /config/credentials.yml.enc /config/database.yml
    /credentials.json /secrets.json /key.json /firebase.json
    /firebase-adminsdk.json /google-credentials.json /gcp-credentials.json
    /service-account.json /account.json /appsettings.json
    /db/schema.rb /Gemfile /Dockerfile /docker-compose.yml
    /serverless.yml /serverless.yaml /terraform.tfstate /terraform.tfvars /.terraform
    /wp /wordpress /xmlrpc.php /telescope /_ignition /v2/_catalog
    /api/config /api/env /actuator
  ].freeze

  blocklist("block/sensitive-file-probe") do |req|
    SENSITIVE_PATHS.any? { |path| req.path.start_with?(path) }
  end

  # Rotte ActiveStorage: Rails LE SERVE DAVVERO, quindi il rationale delle blocklist sonde sotto
  # ("l'app è Rails, questi path non esistono mai") non vale qui. Vanno esentate perché le URL dei blob
  # portano il NOME DEL FILE come ultimo segmento di path
  # (/rails/active_storage/blobs/redirect/:signed_id/:filename): senza esenzione un allegato
  # legittimo chiamato `deploy.cgi` o `install.php` riceverebbe un 404 silenzioso al download, con
  # una diagnosi tutt'altro che ovvia (CYRA-176). Il filename NON è codice eseguibile: i blob vivono
  # su S3 e nessun interprete esiste nell'immagine.
  ACTIVE_STORAGE_PREFIX = "/rails/active_storage/"

  # Direct upload: montata di default da ActiveStorage ma MAI usata lato client (nessun
  # @rails/activestorage in importmap.rb né in app/javascript). Va chiusa perché crea blob dai
  # metadata DICHIARATI dal client, scavalcando lo sniff Marcel dei service di upload — che è l'unico
  # gate reale sul tipo di file. Chi carica passa dai form multipart dell'app.
  # Il trailing slash NON è cosmetico: Rails instrada `/rails/active_storage/direct_uploads/`
  # esattamente come la forma senza slash, quindi un confronto per uguaglianza si aggira con un
  # carattere. Verificato con routes.recognize_path su entrambe le forme.
  DIRECT_UPLOADS_PATH = %r{\A/rails/active_storage/direct_uploads(?:\.[^/]+)?/?\z}

  blocklist("block/direct-uploads") do |req|
    req.path.match?(DIRECT_UPLOADS_PATH)
  end

  # Probe a estensioni di altri stack: l'app è Rails, mai PHP → blocco sicuro (404 silenzioso).
  # Sovrappone in parte SCANNER_PROBE_EXT sotto (regola canonica condivisa tra i repo).
  blocklist("block/php-probe") do |req|
    req.path.end_with?(".php") && !req.path.start_with?(ACTIVE_STORAGE_PREFIX)
  end

  # Blocklist sonde scanner CMS/PHP. L'app è Rails: questi path non esistono mai.
  # rack-attack è middleware → blocca PRIMA del router → 404 silenzioso, nessuna
  # ActionController::RoutingError nei log. I 404 legittimi (path sconosciuti non
  # scanner) restano gestiti da Rails come sempre. Vedi rules/rails/security.md.
  SCANNER_PROBE_REGEX = %r{
    \A/(?:
      wp[-/]|wp\z|wordpress|xmlrpc|
      phpmyadmin|phpMyAdmin|pma\z|myadmin|mysqladmin|
      administrator(?:/|\z)|joomla|drupal|typo3|
      \.git(?:/|\z)|\.svn|\.hg|\.aws(?:/|\z)|\.ssh(?:/|\z)|
      cgi-bin|vendor/phpunit|phpinfo
    )
  }xi

  # Estensioni server-side che Rails non serve mai.
  SCANNER_PROBE_EXT = /\.(?:php\d?|phtml|asp|aspx|jsp|cgi)\z/i

  blocklist("block/scanner-probe") do |req|
    !req.path.start_with?(ACTIVE_STORAGE_PREFIX) &&
      (req.path.match?(SCANNER_PROBE_REGEX) || req.path.match?(SCANNER_PROBE_EXT))
  end

  self.blocklisted_responder = lambda do |_req|
    [ 404, { "Content-Type" => "text/plain" }, [ "Not Found" ] ]
  end

  # Throttle login — 10 tentativi / 15 min per IP. Il POST del login è /login (non /session): con il
  # path sbagliato il throttle non matchava mai e il login restava non protetto (CYRA-170 FIX-1).
  throttle("login/ip", limit: 10, period: 15.minutes) do |req|
    req.ip if req.path.match?(%r{\A/login(?:\.[^/]+)?/?\z}) && req.post?
  end

  # Throttle secondo fattore 2FA — 10 tentativi / 15 min per IP. Senza, il codice TOTP a 6 cifre è
  # brute-forzabile nella finestra pending (10 min): 10 tentativi/15min lo rendono infattibile (CYRA-170).
  throttle("two_factor/ip", limit: 10, period: 15.minutes) do |req|
    req.ip if req.path.match?(%r{\A/login/2fa(?:\.[^/]+)?/?\z}) && req.post?
  end

  # Throttle gestione 2FA account (attivazione/disattivazione) — 10 / 15 min per IP. enable/destroy
  # accettano password/TOTP/recovery per la re-auth: senza limite una sessione rubata brute-forza la
  # password o i codici. Copre POST /account/2fa/enable e DELETE /account/2fa (CYRA-170 FIX-I).
  throttle("two_factor_manage/ip", limit: 10, period: 15.minutes) do |req|
    req.ip if req.path.start_with?("/account/2fa") && (req.post? || req.delete?)
  end

  # Throttle avvio impersonation — 10 tentativi / 15 min per IP (CYRA-719). Entrare nei panni di un
  # altro utente è la capacità god più pericolosa e l'avvio ora chiede un codice a sei cifre: senza
  # freno quel codice è indovinabile a raffica da una sessione god rubata. Stesso limite del login e
  # del secondo fattore, che è la stessa moneta. `start_with?` copre `/impersonation.json` e il
  # trailing slash: le rotte instradano anche con estensione e cinque caratteri non devono aggirare il
  # limite (CYRA-251). Solo POST: l'USCITA (DELETE) non va mai frenata, o un god che sta impersonando
  # resterebbe intrappolato nei panni della vittima.
  throttle("impersonation/ip", limit: 10, period: 15.minutes) do |req|
    req.ip if req.post? && req.path.start_with?("/impersonation")
  end

  # Throttle password reset — 3 / ora per IP.
  throttle("password_reset/ip", limit: 3, period: 1.hour) do |req|
    req.ip if req.path.match?(%r{\A/passwords(?:\.[^/]+)?/?\z}) && req.post?
  end

  # Throttle accettazione invito — 10 / 15 min per IP (CYRA-249). Chiusa /signup, questa è l'unica
  # richiesta anonima che crea un Account: il token è firmato e non si indovina, ma ogni via pubblica
  # che crea credenziali ha il suo freno, come login e reset. L'update dell'invito arriva in PATCH
  # (o PUT dal fallback dei form): il GET del modulo non consuma nulla e resta fuori.
  throttle("invitation_accept/ip", limit: 10, period: 15.minutes) do |req|
    req.ip if req.path.start_with?("/invitations/") && (req.patch? || req.put?)
  end

  # Throttle API — 300 / minuto per IP. Le richieste che hanno il proprio tetto per credenziale
  # (le scritture di una sonda autenticata: servers_ingest/agent sotto) escono da qui, e tenerle
  # dentro era la causa del guasto di CYRA-775. Questo contatore è condiviso da tutto /api — errori,
  # log, misure e visite di OGNI applicazione monitorata — e in un'installazione le applicazioni e le
  # sonde escono dallo stesso gateway: il consumo altrui rifiutava le sonde, il loro push non
  # arrivava, e la staleness leggeva quel silenzio come «macchina caduta».
  #
  # L'uscita vale SOLO per ciò che il tetto dedicato prende in carico davvero: senza Bearer, su un
  # path del namespace che non è una delle tre scritture, o in lettura, la richiesta resta qui. Un
  # buco per prefisso avrebbe lasciato senza alcun freno il traffico anonimo verso le stesse rotte,
  # che pur finendo in 401 costa comunque una risoluzione di credenziale a testa.
  throttle("api/ip", limit: 300, period: 1.minute) do |req|
    req.ip if req.path.start_with?("/api/") && Rack::Attack.agent_ingest_key(req).nil?
  end

  # Throttle webhook Telegram — 60 / minuto per IP (generoso per Telegram, taglia gli scanner che
  # sondano /telegram/webhook con secret errato).
  throttle("telegram_webhook/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.post? && req.path.start_with?("/telegram/webhook")
  end

  # Throttle webhook GitHub — 120 / minuto per IP (difesa in profondità: il gate vero è la firma HMAC;
  # taglia gli scanner che sondano /github/webhook con firma errata).
  throttle("github_webhook/ip", limit: 120, period: 1.minute) do |req|
    req.ip if req.post? && req.path.start_with?("/github/webhook")
  end

  # Suffisso di path condiviso da ogni throttle che matcha un path ESATTO (gli ingest per-progetto e
  # i «chiedi» dell'assistente CLI): estensione di formato opzionale (.json, .JSON, .J1, .Xml…)
  # seguita dal trailing slash opzionale. Le rotte instradano ANCHE con estensione, quindi il limite
  # DEVE valere identico su ogni forma dell'indirizzo: senza questo suffisso, aggiungere `.json` (o
  # cinque caratteri qualsiasi) all'indirizzo aggirava il throttle e — non superando alcun limite —
  # l'abuso non lasciava traccia (CYRA-251). `[^/]+` copre QUALSIASI formato (maiuscole e cifre
  # incluse), non solo il vecchio `(?:\.[a-z]+)?` che lasciava passare .JSON e .J1.
  PATH_FORMAT_SUFFIX = %r{(?:\.[^/]+)?/?\z}

  # Le sei regex per-progetto riusano il suffisso condiviso. La chiave del throttle è sempre il
  # project_id catturato — ([^/]+), gruppo 1 — perché il suffisso è non-catturante.
  INGEST_ENVELOPE_STORE_PATH = %r{\A/api/([^/]+)/(?:envelope|store|minidump)#{PATH_FORMAT_SUFFIX}}
  INGEST_EVENTS_PATH         = %r{\A/api/v1/projects/([^/]+)/events#{PATH_FORMAT_SUFFIX}}
  INGEST_METRICS_PATH        = %r{\A/api/v1/projects/([^/]+)/metrics#{PATH_FORMAT_SUFFIX}}
  INGEST_LOGS_PATH           = %r{\A/api/v1/projects/([^/]+)/logs#{PATH_FORMAT_SUFFIX}}
  INGEST_PAGEVIEWS_PATH      = %r{\A/api/v1/projects/([^/]+)/pageviews#{PATH_FORMAT_SUFFIX}}
  INGEST_REPLAYS_PATH        = %r{\A/api/v1/projects/([^/]+)/replays#{PATH_FORMAT_SUFFIX}}
  INGEST_WEB_VITALS_PATH     = %r{\A/api/v1/projects/([^/]+)/web_vitals#{PATH_FORMAT_SUFFIX}}
  HELPDESK_REQUESTS_PATH     = %r{\A/api/v1/projects/([^/]+)/helpdesk_requests#{PATH_FORMAT_SUFFIX}}

  # Discriminatore per-progetto: il project_id catturato va DECODIFICATO, non usato grezzo. req.path è
  # PATH_INFO ancora URL-encoded, ma Rails instrada ogni percent-encoding (`/api/%35%35%30e…/envelope`)
  # allo stesso progetto: senza normalizzare, la stessa risorsa cade su chiavi diverse e il limite si
  # aggira variando la codifica — lo stesso vettore già chiuso per lo slug in share_analytics_password
  # (CYRA-247, CYRA-251). URI (non Rack::Utils, che tratta "+" come spazio) replica la decodifica di Rails.
  def self.ingest_project_key(req, pattern)
    return unless req.post? && (match = pattern.match(req.path))

    identifier = URI::DEFAULT_PARSER.unescape(match[1])
    if pattern == INGEST_ENVELOPE_STORE_PATH && identifier.match?(/\A[1-9][0-9]{0,15}\z/)
      # Canonicalize only this public identifier; authorization remains in the controller.
      Projects::Project.where(sentry_project_id: identifier.to_i).pick(:id) || identifier
    else
      identifier
    end
  end

  # Throttle ingest PER-PROGETTO — l'ingest arriva in volume da un solo IP server: throttlare per IP
  # sarebbe sbagliato. Chiave = project_id del path /api/:project_id/{envelope,store}. Il trailing
  # slash opzionale è OBBLIGATORIO nel pattern: gli SDK Sentry ufficiali postano su /envelope/ .
  throttle("ingest/project", limit: 600, period: 1.minute) do |req|
    Rack::Attack.ingest_project_key(req, INGEST_ENVELOPE_STORE_PATH)
  end

  # Throttle metriche PER-PROGETTO — slow query/method arrivano in volume alto da un solo IP server.
  # Chiave = project_id del path /api/v1/projects/:project_id/metrics.
  throttle("metrics/project", limit: 1200, period: 1.minute) do |req|
    Rack::Attack.ingest_project_key(req, INGEST_METRICS_PATH)
  end

  # Throttle log PER-PROGETTO — i log sono alto-volume (un POST può portare un batch). Chiave =
  # project_id del path /api/v1/projects/:project_id/logs.
  throttle("logs/project", limit: 1200, period: 1.minute) do |req|
    Rack::Attack.ingest_project_key(req, INGEST_LOGS_PATH)
  end

  # Throttle pageview PER-PROGETTO — a differenza degli altri ingest gli IP sorgente sono molti
  # (i browser dei visitatori), quindi la chiave per-progetto resta quella corretta: protegge il
  # backend da un singolo sito impazzito senza penalizzare i visitatori legittimi.
  throttle("pageviews/project", limit: 600, period: 1.minute) do |req|
    Rack::Attack.ingest_project_key(req, INGEST_PAGEVIEWS_PATH)
  end

  # Throttle misure di velocità PER-PROGETTO — stessa ragione dei pageview (gli IP sorgente sono i
  # browser dei visitatori) e stesso ordine di grandezza: un caricamento produce un pageview e una
  # manciata di misure, che il client manda in una richiesta sola.
  throttle("web_vitals/project", limit: 600, period: 1.minute) do |req|
    Rack::Attack.ingest_project_key(req, INGEST_WEB_VITALS_PATH)
  end

  # Throttle errori (bearer) PER-PROGETTO — /api/v1/projects/:project_id/events arriva in volume da
  # un solo IP server: come metrics/logs, la chiave corretta è il project_id, non l'IP (il limite
  # per-IP 300/min è condiviso con tutte le API e non protegge il progetto).
  throttle("events/project", limit: 1200, period: 1.minute) do |req|
    Rack::Attack.ingest_project_key(req, INGEST_EVENTS_PATH)
  end

  # Help desk requests are written by people, one at a time: both limits sit far below telemetry.
  # Per project, so one site cannot flood the inbox; per address, so one visitor cannot either. CYRA-940
  throttle("helpdesk/project", limit: 30, period: 1.minute) do |req|
    Rack::Attack.ingest_project_key(req, HELPDESK_REQUESTS_PATH)
  end

  throttle("helpdesk/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && HELPDESK_REQUESTS_PATH.match?(req.path)
  end

  # Throttle session replay PER-PROGETTO — i chunk rrweb sono pesanti: limite più basso.
  throttle("replays/project", limit: 600, period: 1.minute) do |req|
    Rack::Attack.ingest_project_key(req, INGEST_REPLAYS_PATH)
  end

  # Le tre scritture di una sonda: push delle misure, presa in carico di un'azione e suo esito.
  # Stanno insieme (CYRA-775) perché sono le tre richieste dello stesso agent e devono avere lo
  # stesso destino — prima il tetto dedicato copriva il solo push, e la presa in carico finiva nel
  # contatore generale di /api con tutto il resto. `actions/:id` porta l'identificativo dell'azione,
  # che NON entra nella chiave: il conteggio è della sonda, non della singola azione.
  AGENT_INGEST_PATH = %r{\A/api/v1/servers/(?:samples|action_claims|actions/[^/]+)#{PATH_FORMAT_SUFFIX}}

  # La chiave di una scrittura di sonda, o nil se la richiesta non è tale. Punto unico di verità:
  # la usano sia il tetto dedicato sia l'uscita da `api/ip`, che devono coincidere esattamente — se
  # divergessero, qualcosa uscirebbe dal contatore generale senza entrare in nessun altro.
  def self.agent_ingest_key(req)
    return nil unless req.post? || req.patch? || req.put?
    return nil unless req.path.match?(AGENT_INGEST_PATH)

    bearer_token_key(req)
  end

  # Throttle ingest server monitoring PER-CREDENZIALE (CYRA-775) — prima era per indirizzo IP, con la
  # premessa scritta «1 agent per host, il limite per-IP basta». La premessa è falsa: una flotta esce
  # da un solo gateway, quindi ventidue sonde si presentavano come un unico indirizzo e si rubavano
  # la quota a vicenda — oltre a condividerla con l'ingest applicativo di ogni progetto. La chiave
  # giusta è quella che identifica CHI pusha, come per l'assistente da CLI.
  #
  # 600/min, non 60: a regime la credenziale è per macchina (CYRA-245) e nessuna sonda le userebbe
  # mai, ma durante l'arruolamento — e per le sonde più vecchie della credenziale per-host — vale il
  # codice della flotta, che è lo STESSO su ogni macchina dell'organizzazione. Il tetto deve quindi
  # reggere l'intera flotta: 600 al minuto sono duecento macchine a tre richieste ciascuna.
  throttle("servers_ingest/agent", limit: 600, period: 1.minute) do |req|
    Rack::Attack.agent_ingest_key(req)
  end

  # Throttle del polling device-flow — chiave = device_code (la CLI fa poll a `interval`; lo slow_down
  # alza l'intervallo). Limita l'abuso di un singolo device_code senza penalizzare il polling legittimo.
  throttle("cli_device_token/code", limit: 30, period: 1.minute) do |req|
    req.params["device_code"].presence if req.post? && req.path == "/cli/device/token"
  end

  # Throttle della pagina di approvazione CLI per IP — blunt del guessing del user_code.
  throttle("cli_authorize/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.path == "/cli/authorize" || req.path.start_with?("/cli/authorize/")
  end

  # Throttle status page PUBBLICA per IP — le rotte /status/:org/:key/:env (per-monitor) e
  # /status/g/:org/:group (per-gruppo) sono enumerabili. Non rivelano nulla (non pubblicato → 404),
  # ma il limite frena scraping/enumeration/DoS. `start_with?("/status/")` copre entrambe.
  throttle("public_status/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.get? && req.path.start_with?("/status/")
  end

  # Throttle aperture statistiche condivise PUBBLICHE per IP — /share/analytics/:slug è un link
  # capability incollabile in una pagina o dentro un iframe: ogni GET ricalcola da zero decine di
  # aggregati pesanti sull'intero storico (Analytics::Snapshot) sullo stesso DB che riceve gli errori
  # di tutte le app. Senza freno un iframe su una pagina trafficata o poche decine di richieste insieme
  # lo saturano. Gemella di public_status/ip: stesso limite, stessa forma (CYRA-247).
  throttle("share_analytics/ip", limit: 60, period: 1.minute) do |req|
    req.ip if req.get? && req.path.start_with?("/share/analytics/")
  end

  # Throttle tentativi password del link condiviso PER-SLUG — il POST /share/analytics/:slug verifica
  # la password (bcrypt) senza alcun limite: brute-forzabile a oltranza. La chiave è lo SLUG, non l'IP,
  # così il conteggio protegge il singolo link anche da un brute-force distribuito su più IP. Molto più
  # stretto delle aperture, sul modello di login/ip: 10 tentativi / 15 min (CYRA-247).
  throttle("share_analytics_password/slug", limit: 10, period: 15.minutes) do |req|
    next unless req.post? && req.path =~ %r{\A/share/analytics/([^/]+)/?\z}

    # PATH_INFO resta URL-encoded, ma il controller decodifica lo slug prima del find_by: senza
    # normalizzare, `%61bc` e `abc` colpiscono lo stesso link con chiavi diverse e il limite si aggira
    # variando la codifica. URI (non Rack::Utils, che tratta "+" come spazio) replica la decodifica di
    # Rails, così ogni codifica dello stesso link cade sulla stessa chiave (CYRA-247).
    URI::DEFAULT_PARSER.unescape(Regexp.last_match(1))
  end

  # Throttle AI Buddy (compose ticket) PER-IP — endpoint member autenticato che spende una chiamata
  # LLM a ogni click. 20/min per IP frena l'abuso senza penalizzare l'uso legittimo.
  throttle("ticket_compose/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/member/tickets/compose"
  end

  # Throttle salvataggi knowledge PER-IP (CYRA-764) — ogni create/update di pagina spende una chiamata
  # sincrona al revisore (10-25 s di modello). 20/min per IP: nessuno scrive più di una pagina ogni
  # tre secondi, un modulo in ciclo sì.
  throttle("knowledge_write/ip", limit: 20, period: 1.minute) do |req|
    next unless req.post? || req.patch? || req.put?

    req.ip if req.path.match?(%r{\A/member/knowledge/pages(?:/[^/]+)?\z})
  end

  # Throttle assistente help PER-IP — copre l'invio messaggi (spende una chiamata al server AI) E la
  # creazione di conversazioni (scrittura DB): entrambi POST sotto /member/assistant/conversations.
  # 30/min per IP frena loop/script senza intralciare una conversazione reale.
  throttle("assistant/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.post? && req.path.start_with?("/member/assistant/conversations")
  end

  # Throttle assistente da CLI/app PER-TOKEN (CYRA-527) — unico caso del file contato su un token, e
  # non su un IP o su un progetto. Prima di questi due limiti /cli/v1 non aveva alcun freno, e
  # l'assistente è il solo endpoint del prodotto in cui UNA richiesta HTTP può costare come decine:
  # ogni domanda spende più chiamate al modello, più la ricerca semantica. Un client entrato in ciclo
  # era un rubinetto aperto sui costi.
  #
  # Perché NON per IP: il client è una CLI o un'app, che in mobilità cambia indirizzo di continuo e in
  # rete mobile lo condivide con altri. Per IP il limite sarebbe insieme aggirabile (basta cambiare
  # rete) e ingiusto (due utenti dietro lo stesso NAT si ruberebbero la quota).
  #
  # L'assistente del sito resta per IP (assistant/ip sopra): lì la richiesta porta un cookie di
  # sessione, non un token, e l'IP di un browser loggato non cambia a ogni messaggio.
  ASSISTANT_CLI_PREFIX = "/cli/v1/assistant/"

  # I due «chiedi» (RAG sui ticket e sulla knowledge base) spendono la stessa moneta dell'assistente e
  # dalla CLI erano senza freno come lui: entrano nello stesso contatore. Sono path esatti, quindi
  # l'estensione di formato va scritta — il prefisso sopra la copre da sé.
  ASSISTANT_CLI_ASK_PATH = %r{\A/cli/v1/(?:tickets|knowledge)/ask#{PATH_FORMAT_SUFFIX}}

  # L'esito di una richiesta AI asincrona: il client lo interroga a intervalli esattamente come lo
  # stato di una risposta dell'assistente, quindi vale il tetto delle letture e non quello delle
  # domande.
  AI_REQUEST_CLI_PREFIX = "/cli/v1/ai/requests/"

  # Discriminatore per-token, condiviso da chiunque si presenti con un Bearer — la CLI, l'assistente
  # e le sonde di server monitoring (CYRA-775). rack-attack è middleware: gira PRIMA del router,
  # quindi Current.api_token non esiste ancora e il token va letto dall'header. Si conta sul digest
  # TRONCATO del segreto: la chiave finisce nella cache dei contatori e nella riga di log del throttle
  # scattato (che il self-monitoring raccoglie), quindi non deve essere né il segreto in chiaro né il
  # digest intero con cui il DB riconosce il token (UserTokenAuthentication, Servers::HostToken). 32
  # esadecimali = 128 bit: distinguono i token senza collisioni pratiche.
  BEARER_TOKEN_KEY_CHARS = 32

  def self.bearer_token_key(req)
    header = req.get_header("HTTP_AUTHORIZATION").to_s
    return nil unless header.start_with?("Bearer ")

    presented = header.delete_prefix("Bearer ").strip
    return nil if presented.empty?

    Digest::SHA256.hexdigest(presented)[0, BEARER_TOKEN_KEY_CHARS]
  end

  # Le DOMANDE (invio del messaggio, apertura/cancellazione della conversazione, i due «chiedi»):
  # 20/min è molto sopra una conversazione umana — una domanda ogni tre secondi, sostenuta — e taglia
  # netto un client entrato in ciclo. Senza token la chiave è nil e il throttle non matcha: a una
  # richiesta non autenticata risponde già l'autenticazione, senza spendere nulla in AI.
  throttle("assistant_cli/token", limit: 20, period: 1.minute) do |req|
    next unless req.post? || req.delete?
    next unless req.path.start_with?(ASSISTANT_CLI_PREFIX) || req.path.match?(ASSISTANT_CLI_ASK_PATH)

    Rack::Attack.bearer_token_key(req)
  end

  # Le scritture knowledge dalla CLI (pagina e pubblicazione per chiave) spendono la stessa moneta del
  # revisore (CYRA-764): stesso tetto, stesso discriminatore per token.
  KNOWLEDGE_CLI_WRITE_PATH = %r{\A/cli/v1/(?:knowledge/pages(?:/[^/]+)?|projects/[^/]+/knowledge/publications/[^/]+)#{PATH_FORMAT_SUFFIX}}

  throttle("knowledge_cli_write/token", limit: 20, period: 1.minute) do |req|
    next unless req.post? || req.patch? || req.put?
    next unless req.path.match?(KNOWLEDGE_CLI_WRITE_PATH)

    Rack::Attack.bearer_token_key(req)
  end

  # Le LETTURE (storia della conversazione e attesa della risposta) restano larghe di proposito: il
  # client interroga lo stato circa una volta al secondo mentre aspetta, e un tetto stretto qui
  # strozzerebbe l'attesa legittima invece dell'abuso. Il limite serve solo contro un client impazzito.
  throttle("assistant_cli_read/token", limit: 300, period: 1.minute) do |req|
    next unless req.get?
    next unless req.path.start_with?(ASSISTANT_CLI_PREFIX, AI_REQUEST_CLI_PREFIX)

    Rack::Attack.bearer_token_key(req)
  end

  # Retry-After: gli SDK (Sentry inclusi) lo leggono per il backoff — senza, ripiegano su un
  # default cieco. match_data espone period ed epoch del match: secondi alla prossima finestra.
  self.throttled_responder = lambda do |req|
    match_data = req.env["rack.attack.match_data"] || {}
    period = match_data[:period].to_i
    retry_after = period.positive? ? period - (match_data[:epoch_time].to_i % period) : 60

    [ 429, { "Content-Type" => "application/json", "Retry-After" => retry_after.to_s },
      [ { error: { code: "R429-SYSTEM-001", message: "Too many requests" } }.to_json ] ]
  end
end

# Osservabilità dei limiti (CYRA-109, Definition of Done): ogni throttle scattato emette un log warn
# con la regola e il discriminatore (progetto o IP). Il self-monitoring (closeyourit-ruby) cattura i
# log Rails warn+ → le quote diventano visibili nel monitoring (chi/quale progetto sta saturando).
# rack-attack pubblica "throttle.rack_attack" SOLO quando un throttle scatta (match_type :throttle).
ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  request = payload[:request]
  next unless request

  Rails.logger.warn(
    "[rack-attack] throttled rule=#{request.env['rack.attack.matched']} " \
    "discriminator=#{request.env['rack.attack.match_discriminator']} " \
    "path=#{request.path} ip=#{request.ip}"
  )

  # CYRA-775 — un rifiuto a una sonda va anche RICORDATO, non solo scritto nel log: è l'unico modo
  # perché il giro che giudica la salute delle macchine sappia che quel silenzio è nostro. Si ricorda
  # la CREDENZIALE rifiutata, non un semplice «è successo»: chi la ricorda non sa ancora se
  # appartiene a una macchina vera — lo risolve Servers::IngestRejections, così un Bearer inventato
  # non compra il silenzio di nessuno. Si ricalcola la chiave invece di leggere il discriminatore
  # della regola scattata: qualunque freno rifiuti una sonda produce lo stesso buco nei dati, e
  # domani i freni potrebbero essere altri.
  agent_key = Rack::Attack.agent_ingest_key(request)
  Servers::IngestRejections.record!(agent_key) if agent_key
end
