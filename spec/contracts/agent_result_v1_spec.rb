# frozen_string_literal: true

require "rails_helper"
require "digest"
require "json_schemer"

# Contract del delivery result (CYAU-97, clean break skill-mode). Verifica lo snapshot vendorizzato
# (checksum-pin, gemello di agent_queue_v1_spec), che gli schemi per-fase del contratto canonico
# (Draft 2020-12) accettino/rifiutino le golden fixtures e che l'endpoint reale del result accetti un
# delivery envelope conforme al contratto — così il wire che il server pretende resta legato al contratto.
RSpec.describe "Agent result contract v1", type: :request do
  # let (non costanti top-level): evita la collisione globale con CONTRACT_ROOT/CONTRACT di altri contract spec.
  let(:contract_root) { Rails.root.join("contracts/agent-result") }
  let(:contract) { contract_root.join("v1") }

  def contract_schema
    @contract_schema ||= JSON.parse(contract.join("schema.json").read)
  end

  # CYAU-173 — stesse regole del servizio che valida davvero (Agents::Attempts::Deliver): ECMA-262,
  # come il contratto dichiara. Da CYRA-638 vivono in `ContractSchemer` (spec/support), perche' questa
  # riga era copiata in tre spec e due erano rimaste indietro.
  def schema_errors(definition, document)
    contract_errors(contract_schema, definition, document)
  end

  it "corrisponde allo snapshot canonico bloccato e a tutti i checksum" do
    lock = JSON.parse(contract_root.join("LOCK.json").read)
    sums = contract.join("SHA256SUMS").read
    expect(Digest::SHA256.hexdigest(sums)).to eq(lock.fetch("sha256sums"))

    sums.each_line do |line|
      expected, relative = line.strip.split("  ./", 2)
      expect(Digest::SHA256.file(contract.join(relative)).hexdigest).to eq(expected), relative
    end
  end

  # CYRA-598 — SHA256SUMS deve elencare ESATTAMENTE i file presenti: né uno in meno, né uno in più.
  #
  # Il controllo qui sopra scorre le RIGHE del file, quindi un file aggiunto e non elencato non lo
  # vede: entra nel bundle, non entra nel digest, e il pin continua a dirsi valido. È la stessa
  # condizione che impone il verificatore canonico (`assert set(expected) == actual_files`), e che i
  # due gemelli non avevano.
  #
  # L'ORDINE non si verifica, di proposito: il file canonico è generato con `sort` di sistema, che
  # ordina secondo la localizzazione della macchina — asserirlo darebbe rossi su una macchina
  # configurata diversamente, cioè un falso allarme al posto di un controllo.
  #
  # Resta scoperto il caso che ha originato questo lavoro: un LOCK che dichiara un commit il cui
  # bundle è diverso dal proprio. Nessun controllo locale può vederlo — servirebbe leggere
  # closeyourit-docs al commit dichiarato, ed è privato: senza una credenziale cross-repo, che oggi
  # non esiste su nessuno dei due repository, quel controllo non è scrivibile. Non è stata scritta
  # una versione finta che passa sempre.
  it "elenca esattamente i file del bundle, nessuno escluso" do
    presenti = contract.glob("**/*").select(&:file?).reject { |f| f.basename.to_s == "SHA256SUMS" }
                       .map { |f| "./#{f.relative_path_from(contract)}" }.sort
    elencati = contract.join("SHA256SUMS").read.each_line.filter_map do |line|
      line.strip.split("  ./", 2).last&.then { |relative| "./#{relative}" }
    end.sort

    expect(elencati).to eq(presenti)
  end

  it "accetta e rifiuta ogni golden fixture contro il suo $def (parità col verify canonico)" do
    manifest = JSON.parse(contract.join("manifest.json").read)
    manifest.fetch("fixtures").each do |fixture|
      document = JSON.parse(contract.join(fixture.fetch("path")).read)
      errors = schema_errors(fixture.fetch("definition"), document)
      if fixture.fetch("valid")
        expect(errors).to be_empty, "#{fixture['path']}: #{errors.map { |item| item['error'] }.join(', ')}"
      else
        expect(errors).not_to be_empty, fixture["path"]
      end
    end
  end

  it "l'endpoint del result accetta un delivery envelope conforme al contratto (triage workable)" do
    organization = create(:organization)
    project = create(:project, organization:)
    create(:github_repository, project:)
    ticket = create(:ticket, organization:, project:, with_agent_workflow: true)
    workflow = ticket.agent_workflow
    registration = Agents::Hosts::Register.call(
      organization:, fingerprint: SecureRandom.hex(12), hostname: "runner", platform: "linux", arch: "amd64"
    ).value
    host = registration.fetch(:host)
    host.update!(last_heartbeat_at: Time.current, certified_at: Time.current, repositories: [ project.key ],
                 runtimes: [ { "name" => "claude", "present" => true } ])
    create(:project_membership, account: host.service_account, project:)
    workflow.update!(triage_started_at: Time.current, ticket_snapshot_digest: "snapshot")
    attempt = create(:agent_attempt, organization:, workflow:, host:, service_account: host.service_account,
                                     skill_key: "/closeyourit-triage",
                                     external_run_id: "run-1", phase: "triage", runtime: "claude")
    create(:agent_lease, organization:, ticket:, host:, run_id: "run-1", agent: nil, execution_phase: "triage",
                         profile_digest: Agents::PhaseProfile.for("triage").digest, expires_at: 5.minutes.from_now)

    envelope = JSON.parse(contract.join("fixtures/valid/delivery_envelope.json").read)
    expect(schema_errors("delivery_envelope", envelope)).to be_empty
    # Il code del result deve combaciare col ticket dell'attempt (anti cross-ticket): la fixture porta un code fisso.
    envelope["result"]["code"] = ticket.code
    # CYAU-176 — la profondità della rilettura la aggiunge l'host su ogni consegna, e il server la pretende:
    # un rapporto che non dice COME è stato riletto non passa più. Non è nello schema e non deve esserlo —
    # ci passa perché `review_envelope` ha `additionalProperties` aperto, e così il contratto vendorizzato
    # resta intatto (LOCK.json e i suoi checksum non si toccano). Il giorno in cui il contratto canonico lo
    # chiudesse, questa consegna verrebbe rifiutata: meglio scoprirlo da un test rosso.
    envelope["review"]["depth"] = Agents::PhaseProfile.for("triage").review_depth

    put "/api/v1/agent_attempts/#{attempt.id}/result", params: envelope,
        headers: { "Authorization" => "Bearer #{registration.fetch(:secret)}" }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "status")).to eq("approved")
    expect(workflow.reload.triaged_at).to be_present
  end

  # CYRA-384 — le segnalazioni di sicurezza le scrive la skill in un campo apposta del result
  # (`security_findings`), e il prodotto le mostra come avviso in cima al ticket. Il campo NON è nello
  # schema: ci passa perché ogni result del contratto ha `additionalProperties` aperto, e questo tiene
  # il contratto vendorizzato intatto — LOCK.json e i suoi checksum non si toccano.
  #
  # La prova sta qui perché è qui che il patto è scritto: il giorno in cui il contratto canonico
  # chiudesse `additionalProperties`, la consegna verrebbe rifiutata e l'avviso di sicurezza
  # sparirebbe dalla pagina in silenzio. Meglio scoprirlo da un test rosso.
  it "accetta le segnalazioni di sicurezza nel campo dedicato, senza che siano nello schema" do
    result = JSON.parse(contract.join("fixtures/valid/autopilot_blocked.json").read)
    result["security_findings"] = [
      { "title" => "Credenziali git sondate", "detail" => "Uno script legge ~/.git-credentials.",
        "severity" => "high" }
    ]

    expect(schema_errors("autopilot_result", result)).to be_empty
  end

  # CYAU-173 — la forma dell'URL della PR deve essere giudicata da UNA regola sola. Fino a ieri il
  # contratto si accontentava di `https` + `.../pull/<cifre>` mentre l'automator applicava gia la forma
  # canonica: il lavoro passava il controllo sulla macchina e veniva rifiutato dal server, o il
  # contrario, e in entrambi i casi la sessione era gia stata pagata per intero.
  describe "delivery.prUrl — solo la forma che GitHub potrebbe aver prodotto" do
    def con_pr_url(url, stato: "delivered")
      fixture = stato == "delivered" ? "autopilot_delivered.json" : "autopilot_already_delivered.json"
      result = JSON.parse(contract.join("fixtures/valid/#{fixture}").read)
      result["delivery"]["prUrl"] = url
      result
    end

    # Le sette forme finte del ticket. Il pattern vecchio le accettava tutte.
    {
      "senza owner e repo" => "https://github.com/pull/123",
      "con credenziali" => "https://alessio:segreto@github.com/bussolabs/closeyourit-rails/pull/123",
      "numero zero" => "https://github.com/bussolabs/closeyourit-rails/pull/0",
      "numero con zeri davanti" => "https://github.com/bussolabs/closeyourit-rails/pull/007",
      "pull in mezzo al percorso" => "https://github.com/bussolabs/closeyourit-rails/tree/main/pull/123",
      "repo percent-encoded" => "https://github.com/bussolabs/closeyourit%2Drails/pull/123",
      "sito qualunque che lo incorpora" => "https://t.esempio.test/r/github.com/a/b/pull/123"
    }.each do |etichetta, url|
      it "rifiuta un prUrl #{etichetta}, su entrambi i rami" do
        [ "delivered", "already-delivered" ].each do |stato|
          errori = schema_errors("autopilot_result", con_pr_url(url, stato: stato))
          expect(errori.map { |e| e.fetch("data_pointer") }).to include("/delivery/prUrl"), "#{stato}: #{url}"
        end
      end
    end

    # GHES ha host propri: una lista di domini ammessi romperebbe le installazioni self-hosted.
    it "accetta un host che non e github.com" do
      expect(schema_errors("autopilot_result", con_pr_url("https://git.esempio.test/bussolabs/repo/pull/1"))).to be_empty
    end

    # Un prUrl la cui prima riga e valida ma che poi continua e gia rifiutato, ma da `format: "uri"`,
    # non dal pattern: e' una guardia di regressione su quel format, non sull'ancoraggio. La prova
    # dell'ancoraggio sta nel blocco qui sotto, dove `format` non c'e' a coprire.
    it "rifiuta un prUrl la cui prima riga e valida ma che continua" do
      risultato = con_pr_url("https://github.com/bussolabs/repo/pull/1\nQUALSIASI-COSA")
      expect(schema_errors("autopilot_result", risultato)).not_to be_empty
    end
  end

  # CYAU-173 — JSON Schema dichiara i `pattern` in ECMA-262, dove `^` e `$` ancorano la STRINGA. Ruby li
  # legge come ancore di RIGA, quindi col resolver di default un valore multi-riga passa se la PRIMA riga
  # combacia. Sul `prUrl` non si vedeva perche' `format: "uri"` copriva; sui tag di rilascio, che pattern
  # ce l'hanno e format no, il buco era aperto: `"v0.30.0\n<qualsiasi cosa>"` era un result valido.
  #
  # Questo blocco e' la ragione per cui `regexp_resolver: "ecma"` sta nel servizio, e non un dettaglio di
  # configurazione: toglierlo di la fa diventare rossi questi esempi.
  describe "ancoraggio dei pattern: semantica ECMA-262, non di riga" do
    { "closer_production_result" => "closer_production.json",
      "closer_staging_result" => "closer_staging.json" }.each do |definizione, fixture|
      it "#{definizione}: rifiuta un tag la cui prima riga e valida ma che continua" do
        buono = JSON.parse(contract.join("fixtures/valid/#{fixture}").read)
        expect(schema_errors(definizione, buono)).to be_empty

        cattivo = buono.merge("tag" => "#{buono.fetch("tag")}\nQUALSIASI-COSA")
        expect(schema_errors(definizione, cattivo).map { |e| e.fetch("data_pointer") }).to include("/tag")
      end
    end

    # Se qualcuno togliesse il resolver dal servizio, gli esempi qui sopra resterebbero verdi — usano il
    # loro validatore — e il buco tornerebbe aperto in produzione senza un solo rosso. Qui si interroga
    # l'oggetto che valida davvero.
    it "il servizio che valida in produzione applica la stessa semantica" do
      buono = JSON.parse(contract.join("fixtures/valid/closer_production.json").read)
      validatore = Agents::Attempts::DeliveryContract::RESULT_VALIDATORS.fetch(1).fetch("closer_production_result")
      expect(validatore.valid?(buono)).to be(true)
      expect(validatore.valid?(buono.merge("tag" => "#{buono.fetch("tag")}\nQUALSIASI-COSA"))).to be(false)
    end
  end
end
