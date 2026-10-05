# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "base64"

module Github
  # Client dell'API GitHub (App). Autentica col JWT dell'App per coniare l'installation-token, poi
  # chiama le REST con quel token. Net::HTTP raw, nessuna gem (stesso pattern di Ai::Llm::Client).
  # Il token dell'installazione (valido ~1h) è cache-ato in Solid Cache per installation_id.
  # Isola il provider dal dominio → sostituibile cambiando solo questa classe.
  class Client
    # Errore GitHub con codice R{STATUS}-GITHUB-{SEQ}, mappato dai service in AppError.
    #
    # CYRA-599 — `status` esisteva ma valeva sempre :bad_gateway, quindi chi lo ri-sollevava non
    # poteva distinguere due fatti opposti: «questa proposta non esiste» (risposta definitiva, nessun
    # tentativo la cambia, serve una persona) e «GitHub non risponde» (buco temporaneo, si aspetta e
    # si riprova, non c'è niente da chiedere a nessuno). Ora lo status è quello vero, e `retry_after`
    # porta i secondi che GitHub stesso chiede di aspettare quando li dichiara.
    class Error < StandardError
      attr_reader :code, :status, :retry_after

      def initialize(message, code:, status: :bad_gateway, retry_after: nil)
        super(message)
        @code = code
        @status = status
        @retry_after = retry_after
      end

      # Vero quando riprovare ha senso: il fatto non è stato osservato, il canale era rotto.
      def transient? = status != :not_found
    end

    # Un giro solo per tutto ciò che serve a decidere se una proposta è pronta per una persona.
    # `mergeable` è un enum a tre valori; `parents(first: 2)` basta perché un merge ne ha due, e il
    # secondo è il ramo unito — il dato che serve per legare il merge al codice approvato.
    PULL_REQUEST_STATE_QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            headRefOid
            baseRefName
            state
            isDraft
            mergeable
            mergeCommit { oid parents(first: 2) { nodes { oid } } }
            baseRef { repository { nameWithOwner defaultBranchRef { name } } }
            commits(last: 1) {
              nodes {
                commit {
                  committedDate
                  statusCheckRollup {
                    state
                    contexts(first: 100) {
                      nodes {
                        __typename
                        ... on CheckRun { name conclusion status detailsUrl }
                        ... on StatusContext { context state targetUrl }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL

    API_BASE = "https://api.github.com"
    ACCEPT = "application/vnd.github+json"
    API_VERSION = "2022-11-28"
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 15
    TOKEN_TTL = 50.minutes # < 1h di validità reale del token, con margine

    # Creds lette lazy (ENV[], non fetch): la costruzione non solleva mai → il tab GitHub resta
    # renderizzabile anche senza App configurata (il picker mostra la guida). L'assenza di creds
    # emerge come Client::Error solo quando si tenta davvero una chiamata (app_request).
    def initialize(app_id: Settings::Integrations.value(:gh_app_id),
                   private_key: Settings::Integrations.value(:gh_app_private_key),
                   base_url: API_BASE)
      @app_id = app_id
      @private_key = private_key
      @base_url = base_url
    end

    # Installation access token (valido ~1h), cache in Solid Cache per installation_id — CIFRATO,
    # mai in chiaro (vedi encrypt_token). Niente `fetch`: la cache tiene il testo cifrato, quindi
    # lettura e scrittura passano dalla cifratura.
    def installation_token(installation_id)
      key = token_cache_key(installation_id)
      cached = decrypt_token(Rails.cache.read(key))
      return cached if cached.present?

      data = app_request(Net::HTTP::Post, "/app/installations/#{installation_id}/access_tokens")
      token = data.fetch("token")
      sealed = encrypt_token(token)
      Rails.cache.write(key, sealed, expires_in: TOKEN_TTL) if sealed
      token
    end

    # Metadati dell'installazione (JWT App) → account.login dell'org proprietaria. Per il callback di
    # connessione (GitHub non passa il login nel redirect).
    def installation(installation_id)
      app_request(Net::HTTP::Get, "/app/installations/#{installation_id}")
    end

    # Repo accessibili dall'installazione (per il picker di connessione).
    def repositories(installation_id)
      repositories = []
      page = 1

      loop do
        data = token_request(
          Net::HTTP::Get, installation_id, "/installation/repositories?per_page=100&page=#{page}"
        )
        batch = data.fetch("repositories", [])
        repositories.concat(batch)
        break if batch.empty? || repositories.size >= data.fetch("total_count", repositories.size)

        page += 1
      end

      repositories
    end

    # Contenuto plaintext di un file del repository a uno specifico ref. Un 404 indica file
    # opzionale assente e ritorna nil; encoding inattesi o payload invalidi restano errori gateway.
    def repository_file(installation_id, repo_full_name, path, ref:)
      encoded_path = path.split("/").map { |segment| URI.encode_www_form_component(segment).gsub("+", "%20") }.join("/")
      encoded_ref = URI.encode_www_form_component(ref).gsub("+", "%20")
      data = token_request(
        Net::HTTP::Get, installation_id,
        "/repos/#{repo_full_name}/contents/#{encoded_path}?ref=#{encoded_ref}",
        nil, allow_not_found: true
      )
      return nil if data.nil?

      raise KeyError unless data["encoding"] == "base64"

      Base64.strict_decode64(data.fetch("content").delete("\n"))
    rescue KeyError, ArgumentError
      raise Error.new("GitHub contenuto repository non valido", code: "R502-GITHUB-001")
    end

    # CYRA-599 — l'occhio: lo stato di una proposta di modifica letto dal server, non raccontato
    # dall'agente che ci ha lavorato. Un solo giro, perché ogni campo qui serve a una regola diversa
    # più avanti e chiederli separatamente costerebbe cinque richieste.
    #
    # Restituisce un Hash con: head_sha (il codice esatto dentro la proposta), base_ref, state,
    # draft, mergeable a TRE valori, merge_commit (oid + i genitori), checks (l'elenco dei controlli
    # su QUEL commit) e checks_known.
    #
    # `checks_known` è il campo che rende questo ticket diverso da una comodità. Un elenco vuoto ha
    # due significati opposti — «questo repository non ha controlli automatici» e «non lo so» — e
    # arrivano allo stesso posto: nessun controllo fallito. Qui la seconda diventa un errore, mai una
    # lista vuota: far passare per sano un lavoro che nessuno ha verificato è il guasto peggiore che
    # questo pezzo possa produrre.
    #
    # `mergeable` ha tre risposte, non due: `MERGEABLE`, `CONFLICTING` e `UNKNOWN` — GitHub la calcola
    # in differita, e trattare il terzo caso come un no fa respingere un lavoro sano solo perché è
    # stato guardato troppo presto.
    def pull_request_state(installation_id, repo_full_name, number)
      owner, name = repo_full_name.to_s.split("/", 2)
      raise Error.new("Nome repository non valido", code: "R502-GITHUB-001") if owner.blank? || name.blank?

      payload = graphql(installation_id, PULL_REQUEST_STATE_QUERY,
                        owner:, name:, number: number.to_i)
      pull_request = payload.dig("repository", "pullRequest")
      # Il repository c'è ma la proposta no: è una negazione autorevole, non un canale rotto.
      if pull_request.nil?
        raise Error.new("Proposta di modifica assente su #{repo_full_name}##{number}",
                        code: "R404-GITHUB-010", status: :not_found)
      end

      commit = pull_request.dig("commits", "nodes", 0, "commit")
      rollup = commit&.dig("statusCheckRollup")
      merge_commit = pull_request["mergeCommit"]
      base_repository = pull_request.dig("baseRef", "repository")

      {
        head_sha: pull_request["headRefOid"],
        base_ref: pull_request["baseRefName"],
        state: pull_request["state"],
        draft: pull_request["isDraft"],
        mergeable: pull_request["mergeable"],
        merge_commit: merge_commit && {
          sha: merge_commit["oid"],
          parents: merge_commit.dig("parents", "nodes").to_a.map { |parent| parent["oid"] }
        },
        # Nessun rollup = nessun controllo configurato su quel commit: è un fatto osservato, e si
        # distingue dal «non lo so» perché lì siamo già usciti con un errore.
        checks: rollup ? rollup.dig("contexts", "nodes").to_a : [],
        checks_known: true,
        # CYRA-614 — il ramo di destinazione va confrontato col ramo principale del repository DI
        # DESTINAZIONE, e letto dalla STESSA risposta: prenderlo dal database vorrebbe dire
        # confrontare quello che GitHub dice adesso con quello che noi credevamo ieri, e su una PR da
        # un fork il repository non è nemmeno lo stesso.
        base_repository: base_repository&.dig("nameWithOwner"),
        base_default_branch: base_repository&.dig("defaultBranchRef", "name"),
        # La data del commit osservato: da lì si conta la finestra di grazia entro cui un elenco di
        # controlli vuoto significa «non sono ancora partiti» e non «non ce ne sono».
        head_committed_at: commit&.dig("committedDate")
      }
    end

    # CYRA-621 — i tag del repository, dal più recente. Serve a sapere qual è l'ultimo numero di
    # versione DAVVERO uscito, chiesto sul momento a chi lo sa: non a quello che la macchina si
    # ricorda, e nemmeno all'archivio interno delle versioni, che su sette progetti su otto è vuoto.
    #
    # Paginato ma con un tetto: chi chiama vuole il più alto, e leggere diecimila tag per trovarlo
    # sarebbe una richiesta che non finisce mai su un repository vecchio.
    TAGS_PAGE_SIZE = 100
    TAGS_MAX_PAGES = 10

    def tags(installation_id, repo_full_name)
      collected = []
      (1..TAGS_MAX_PAGES).each do |page_number|
        batch = token_request(
          Net::HTTP::Get, installation_id,
          "/repos/#{repo_full_name}/tags?per_page=#{TAGS_PAGE_SIZE}&page=#{page_number}"
        )
        collected.concat(Array(batch))
        break if Array(batch).size < TAGS_PAGE_SIZE
      end
      collected.filter_map { |tag| tag["name"] }
    end

    # CYRA-620 — «questo commit è dentro quel ramo?».
    #
    # `GET /compare/base...head` risponde con `status` e `behind_by`: quando `head` è contenuto in
    # `base`, `behind_by` è 0. È la domanda che serve per sapere se il codice approvato è DAVVERO
    # atterrato sulla linea principale, e non si può fare leggendo il ramo: la punta si muove, e
    # confrontarla con la sigla approvata direbbe di no ogni volta che qualcun altro spinge dopo.
    #
    # 404 significa che uno dei due riferimenti non esiste: è una risposta autorevole, non un canale
    # rotto, e va distinta — chi chiama chiama una persona invece di riprovare all'infinito.
    def commit_contained?(installation_id, repo_full_name, base, head)
      encoded = "#{URI.encode_www_form_component(base)}...#{URI.encode_www_form_component(head)}"
      data = token_request(Net::HTTP::Get, installation_id, "/repos/#{repo_full_name}/compare/#{encoded}")
      # `ahead_by` counts the commits of `head` that `base` lacks: zero means `head` is inside `base`.
      data["ahead_by"].to_i.zero?
    end

    # Albero completo del repository a un ref, ricorsivo: [{ "path", "type", "sha", "size" }, …].
    # Serve a SCOPRIRE i file invece di indovinarne il path (CYRA-506): in un monorepo i lockfile
    # stanno dove capita. Un repository vuoto o un ref inesistente danno 404 → nil, non un errore:
    # un progetto appena collegato senza commit è uno stato normale, non un guasto.
    #
    # `truncated` è la risposta di GitHub quando l'albero supera il suo limite: in quel caso la lista
    # è PARZIALE. Non la nascondiamo — chi chiama decide, ma deve saperlo.
    def git_tree(installation_id, repo_full_name, ref)
      encoded_ref = URI.encode_www_form_component(ref).gsub("+", "%20")
      data = token_request(
        Net::HTTP::Get, installation_id,
        "/repos/#{repo_full_name}/git/trees/#{encoded_ref}?recursive=1",
        nil, allow_not_found: true
      )
      return nil if data.nil?

      { entries: data.fetch("tree", []), truncated: data["truncated"].present? }
    end

    # Contenuto di un blob per sha. `repository_file` passa dall'API contents, che si RIFIUTA di
    # servire file oltre 1 MB (un package-lock.json li supera di routine): questo endpoint arriva a
    # 100 MB. Lo sha lo fornisce già `git_tree`, quindi non costa una richiesta in più per trovarlo.
    def blob(installation_id, repo_full_name, sha)
      data = token_request(
        Net::HTTP::Get, installation_id, "/repos/#{repo_full_name}/git/blobs/#{sha}",
        nil, allow_not_found: true
      )
      return nil if data.nil?

      raise KeyError unless data["encoding"] == "base64"

      Base64.strict_decode64(data.fetch("content").delete("\n"))
    rescue KeyError, ArgumentError
      raise Error.new("GitHub contenuto repository non valido", code: "R502-GITHUB-001")
    end

    # Un ref git (es. "heads/main" o "tags/v1.2.3") → oggetto con object.sha.
    def ref(installation_id, repo_full_name, ref)
      token_request(Net::HTTP::Get, installation_id, "/repos/#{repo_full_name}/git/ref/#{ref}")
    end

    # CYRA-624 — il commit a cui l'etichetta della versione punta DAVVERO.
    #
    # Un'etichetta annotata non punta a un commit: punta a un oggetto suo, che a sua volta punta al
    # commit. Confrontare senza sciogliere quel passaggio vorrebbe dire confrontare due cose diverse e
    # dire sempre di no. Nil quando l'etichetta non esiste: è una risposta autorevole, non un guasto.
    def tag_commit(installation_id, repo_full_name, tag)
      data = token_request(Net::HTTP::Get, installation_id,
                           "/repos/#{repo_full_name}/git/ref/tags/#{URI.encode_www_form_component(tag)}",
                           nil, allow_not_found: true)
      object = data && data["object"]
      return nil if object.nil?
      return object["sha"] unless object["type"] == "tag"

      annotated = token_request(Net::HTTP::Get, installation_id,
                               "/repos/#{repo_full_name}/git/tags/#{object['sha']}", nil, allow_not_found: true)
      annotated&.dig("object", "sha")
    end

    # I giri di lavorazione partiti su quel commit. Serve a trovare il rilascio: il giro che parte da
    # un'etichetta porta il commit dell'etichetta come `head_sha`.
    def workflow_runs(installation_id, repo_full_name, head_sha)
      data = token_request(Net::HTTP::Get, installation_id,
                           "/repos/#{repo_full_name}/actions/runs?head_sha=#{head_sha}&per_page=50")
      Array(data && data["workflow_runs"])
    end

    # I passaggi di un giro, con l'esito di ciascuno. Non basta l'esito del GIRO: un giro con i
    # passaggi saltati resta verde, e verde lì dentro vuol dire «non ho fatto niente».
    def workflow_run_jobs(installation_id, repo_full_name, run_id)
      data = token_request(Net::HTTP::Get, installation_id,
                           "/repos/#{repo_full_name}/actions/runs/#{run_id}/jobs?per_page=100")
      Array(data && data["jobs"])
    end

    # Crea un ref (branch): ref = "refs/heads/<name>".
    def create_ref(installation_id, repo_full_name, ref, sha)
      token_request(Net::HTTP::Post, installation_id, "/repos/#{repo_full_name}/git/refs", { ref:, sha: })
    end

    # Apre una pull request. Ritorna l'oggetto PR (number, html_url, ...).
    def create_pull(installation_id, repo_full_name, title:, head:, base:, body: nil)
      token_request(
        Net::HTTP::Post, installation_id, "/repos/#{repo_full_name}/pulls",
        { title:, head:, base:, body: }.compact
      )
    end

    # --- Environment secrets (Secrets vault Fase 2). Gli endpoint env-level usano il repository_id
    #     NUMERICO (repository.repo_id), non owner/repo. Richiedono il permesso App "Secrets" RW. ---

    # Public key per cifrare i secret sealed-box prima della PUT. → { "key_id" => ..., "key" => base64 }.
    def environment_public_key(installation_id, repository_id, environment)
      token_request(Net::HTTP::Get, installation_id,
                    "/repositories/#{repository_id}/environments/#{environment}/secrets/public-key")
    end

    # Crea/aggiorna un Environment secret (valore già cifrato + key_id). Risponde 201 (create) o 204 (update).
    def put_environment_secret(installation_id, repository_id, environment, name, encrypted_value:, key_id:)
      token_request(Net::HTTP::Put, installation_id,
                    "/repositories/#{repository_id}/environments/#{environment}/secrets/#{name}",
                    { encrypted_value:, key_id: })
    end

    # Deletes an Environment secret (204). A 404 means it is already gone from GitHub, so it counts as
    # deleted: raising there stopped every later sync before it wrote anything.
    def delete_environment_secret(installation_id, repository_id, environment, name)
      token_request(Net::HTTP::Delete, installation_id,
                    "/repositories/#{repository_id}/environments/#{environment}/secrets/#{name}",
                    allow_not_found: true)
    end

    private

    def token_cache_key(installation_id) = "github:installation_token:#{installation_id}"

    # Il token vale come una password che scrive su repository e secret, e in produzione la cache è
    # una tabella PostgreSQL: in chiaro finirebbe in backup, dump e repliche per ~50 minuti
    # (CYRA-277). Lo cifriamo con le stesse chiavi del vault (ActiveRecord::Encryption).
    # Cifriamo la SOLA voce invece di alzare config.solid_cache.encrypt: quel flag cifrerebbe anche
    # presenza, contatori e throttle — traffico caldo che segreto non è — e la protezione sparirebbe
    # il giorno che il cache store non fosse più Solid Cache.
    # Se la cifratura non è disponibile (chiavi assenti o rotte) NON si scrive: si conia un token a
    # ogni chiamata, che costa una richiesta in più ma non lascia mai un segreto in chiaro.
    def encrypt_token(token)
      ActiveRecord::Encryption.encryptor.encrypt(token)
    rescue ActiveRecord::Encryption::Errors::Base
      nil
    end

    # Voce non decifrabile (chiave ruotata, residuo del vecchio formato in chiaro) = miss, non
    # errore: meglio una chiamata in più a GitHub che un 502 su tutta l'integrazione.
    def decrypt_token(sealed)
      return nil if sealed.blank?

      ActiveRecord::Encryption.encryptor.decrypt(sealed)
    rescue ActiveRecord::Encryption::Errors::Base
      nil
    end

    # Richiesta autenticata col JWT dell'App (solo per coniare i token).
    def app_request(method_class, path, body = nil)
      if @app_id.blank? || @private_key.blank?
        raise Error.new("Credenziali GitHub App assenti", code: "R502-GITHUB-001")
      end

      jwt = AppJwt.new(app_id: @app_id, private_key: @private_key).to_s
      request(method_class, path, body:, authorization: "Bearer #{jwt}")
    end

    # GraphQL risponde 200 anche quando fallisce: l'esito sta nel corpo. Perciò `errors` presente o
    # `data` nullo sono un canale rotto — mai un elenco vuoto, che chi legge scambierebbe per «zero
    # controlli falliti».
    def graphql(installation_id, query, **variables)
      token = installation_token(installation_id)
      body = { query:, variables: }
      payload = request(Net::HTTP::Post, "/graphql", body:, authorization: "Bearer #{token}")

      if payload["errors"].present? || payload["data"].nil?
        message = Array(payload["errors"]).filter_map { |e| e["message"] }.first
        raise Error.new("GitHub GraphQL: #{message || 'risposta senza dati'}", code: "R502-GITHUB-001")
      end

      payload["data"]
    end

    # Richiesta autenticata con l'installation token.
    def token_request(method_class, installation_id, path, body = nil, allow_not_found: false)
      token = installation_token(installation_id)
      request(method_class, path, body:, authorization: "Bearer #{token}", allow_not_found:)
    end

    def request(method_class, path, body:, authorization:, allow_not_found: false)
      uri = URI.join(@base_url, path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      req = method_class.new(uri)
      req["Authorization"] = authorization
      req["Accept"] = ACCEPT
      req["X-GitHub-Api-Version"] = API_VERSION
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      handle(http.request(req), allow_not_found:)
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise Error.new("GitHub timeout", code: "R502-GITHUB-001", status: :bad_gateway)
    end

    # Tre esiti, e l'ordine conta.
    #
    # Il ramo `allow_not_found` resta PRIMO: `repository_file`, `git_tree` e `blob` contano su un nil
    # per dire «non c'è», e spostarlo li farebbe sollevare al posto di rispondere.
    #
    # Poi la distinzione che questo ticket esiste per introdurre. 404/410/403 SENZA segnali di limite
    # sono una negazione autorevole: GitHub ha guardato e ha detto di no. Timeout, 5xx, 429 e i 403
    # che portano i segnali del limite di frequenza sono un canale rotto: GitHub non ha guardato.
    # Confonderli significa chiamare una persona a ogni singhiozzo della rete, oppure restare zitti
    # quando la proposta davvero non c'è.
    def handle(response, allow_not_found: false)
      code = response.code.to_i
      return parse(response.body) if code.between?(200, 299)
      return nil if allow_not_found && code == 404

      if authoritative_negation?(response, code)
        raise Error.new("GitHub: risorsa assente o non accessibile (#{code})",
                        code: "R404-GITHUB-010", status: :not_found)
      end

      raise Error.new("GitHub API errore (#{code})", code: "R502-GITHUB-001",
                      retry_after: retry_after_seconds(response))
    end

    # Un 403 è ambiguo: GitHub lo usa sia per «non hai il permesso» sia per «hai finito la quota».
    # A separarli sono le intestazioni, che finora nessuna riga leggeva.
    def authoritative_negation?(response, code)
      return false unless [ 403, 404, 410 ].include?(code)
      return true unless code == 403

      response["x-ratelimit-remaining"].to_s != "0" && response["retry-after"].blank?
    end

    # Secondi da aspettare, se GitHub li dichiara: `retry-after` è già in secondi, `x-ratelimit-reset`
    # è un istante epoch. Nessuno dei due presente = nessuna indicazione, e chi riprova decide da sé.
    def retry_after_seconds(response)
      explicit_value = response["retry-after"].to_s.strip
      return explicit_value.to_i if explicit_value.match?(/\A\d+\z/)

      reset = response["x-ratelimit-reset"].to_s.strip
      return nil unless reset.match?(/\A\d+\z/)

      [ reset.to_i - Time.current.to_i, 0 ].max
    end

    def parse(raw)
      return {} if raw.to_s.strip.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      raise Error.new("GitHub risposta non valida", code: "R502-GITHUB-001")
    end
  end
end
