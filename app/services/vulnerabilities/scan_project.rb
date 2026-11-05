# frozen_string_literal: true

module Vulnerabilities
  # La scansione di un progetto, dall'inizio alla fine: leggi l'albero del repository, scopri i
  # lockfile, leggili, chiedi a OSV, scrivi le righe; poi controlla i runtime dichiarati. È il punto
  # in cui i pezzi si mettono in fila; ognuno di loro resta usabile e testabile da solo.
  #
  # L'albero si scarica UNA volta e serve due scopi: i lockfile e i file che fissano le versioni di
  # linguaggio. Due passate costerebbero il doppio senza dire nulla di più.
  #
  # Un manifest che fallisce non ferma gli altri: il suo errore resta scritto su di lui
  # (`parse_error`) e la scansione prosegue. Fermare tutto perché un lockfile di un'app secondaria è
  # corrotto significherebbe perdere le vulnerabilità di quella principale. Prosegue, però, SENZA
  # riconciliare quel manifest: le sue vulnerabilità restano note e il controllo risulta incompleto
  # (CYRA-810).
  class ScanProject < ApplicationService
    def initialize(project:, github_client: Github::Client.new, osv_client: Osv::Client.new,
                   eol_client: Eol::Client.new, now: Time.current)
      @project = project
      @github_client = github_client
      @osv_client = osv_client
      @eol_client = eol_client
      @now = now
    end

    def call
      repository = @project.github_repository
      return Result.err(no_repository) if repository.nil?

      tree = fetch_tree(repository)
      discovery = Github::Manifests::Discover.call(project: @project, client: @github_client, tree: tree)
      return discovery if discovery.err?

      check_runtimes(repository, tree)

      packages, unverified = collect_packages(discovery.value)
      return record({}, [], unverified) if packages.empty?

      matches = Osv::Query.call(coordinates: packages.map(&:osv_key).uniq, client: @osv_client,
                                now: @now)
      record(matches, packages, unverified)
    rescue Osv::Client::Error => e
      # OSV irraggiungibile: la scansione di oggi non produce nulla, ma ciò che sappiamo resta.
      # Marcare tutto come risolto perché non abbiamo potuto chiedere sarebbe la bugia peggiore.
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    rescue Github::Client::Error => e
      Result.err(AppError.new(e.message, code: e.code, status: e.status))
    end

    private

    def fetch_tree(repository)
      @github_client.git_tree(repository.installation.installation_id, repository.full_name,
                              repository.default_branch)
    end

    # Ritorna due cose: i pacchetti dei lockfile letti davvero, e i lockfile che NON si è riusciti a
    # leggere. Il secondo insieme conta quanto il primo — è il perimetro che la riconciliazione deve
    # lasciare stare (CYRA-810). Scartare e basta i falliti faceva sembrare verificato tutto il
    # progetto anche quando ne avevamo letto metà.
    def collect_packages(manifests)
      unverified = []

      packages = manifests.flat_map do |manifest|
        result = SyncPackages.call(manifest: manifest, client: @github_client, now: @now)
        next result.value if result.ok?

        unverified << manifest
        []
      end

      [ packages, unverified ]
    end

    # Scrittura e notifica sono due momenti distinti: prima si persiste, poi si avvisa. Se l'alerting
    # fallisce, le righe restano — l'inverso (avvisare di qualcosa che non è stato scritto) manderebbe
    # l'utente su una pagina vuota.
    #
    # Con `matches` e `packages` vuoti questo chiude ciò che era aperto SOLO nei lockfile che siamo
    # riusciti a leggere: là dentro la vulnerabilità non è più dimostrabile. Dove non abbiamo letto
    # non chiude niente — non sapere non è una prova.
    def record(matches, packages, unverified)
      result = RecordFindings.call(project: @project, matches: matches, packages: packages,
                                   unverified_manifest_ids: unverified.map(&:id), now: @now)
      return result if result.err?

      NotifyFindings.call(findings: result.value.opened)
      result
    end

    # I runtime sono un controllo indipendente: un calendario irraggiungibile o un file assente non
    # devono impedire di trovare le vulnerabilità delle librerie, che è il grosso del valore.
    def check_runtimes(repository, tree)
      files = runtime_files(repository, tree)
      return if files.empty?

      result = Runtimes::Check.call(project: @project, files: files, client: @eol_client, now: @now)
      NotifyRuntimes.call(statuses: result.value) if result.ok?
    end

    def runtime_files(repository, tree)
      entries = Array(tree&.dig(:entries)).select do |entry|
        entry["type"] == "blob" &&
          Runtimes::Declared.file?(entry["path"]) &&
          !Vulnerabilities::Ecosystem.ignored_path?(entry["path"])
      end

      entries.each_with_object({}) do |entry, files|
        content = @github_client.blob(repository.installation.installation_id, repository.full_name,
                                      entry["sha"])
        files[entry["path"]] = content if content.present?
      end
    end

    def no_repository
      AppError.new("Il progetto non ha un repository GitHub collegato",
                   code: "R422-VULN-002", status: :unprocessable_content)
    end
  end
end
