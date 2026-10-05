# frozen_string_literal: true

module Vulnerabilities
  # Scarica un lockfile, lo parsa e allinea i pacchetti del manifest a ciò che dichiara.
  #
  # Il contenuto si legge SEMPRE dalla Git Blobs API e mai dall'API contents: quest'ultima si rifiuta
  # di servire file oltre 1 MB, cosa che un `package-lock.json` fa di routine, e lo sha del blob ce
  # l'abbiamo già dall'albero — non costa una richiesta in più.
  #
  # Se il contenuto non è cambiato dall'ultima lettura il parse si salta: è lavoro identico su un
  # input identico. Il confronto con OSV invece si rifà comunque, a monte, perché gli advisory nuovi
  # escono su versioni ferme da mesi.
  class SyncPackages < ApplicationService
    def initialize(manifest:, client: Github::Client.new, now: Time.current)
      @manifest = manifest
      @client = client
      @now = now
    end

    def call
      repository = @manifest.project.github_repository
      return unverified("no_repository", missing_repository) if repository.nil?

      content = fetch(repository)
      return unverified("blob_missing", missing_blob) if content.nil?
      return unverified("too_large", too_large) if content.bytesize > Vulnerabilities::Constants::MAX_MANIFEST_BYTES

      digest = Vulnerabilities::Manifest.digest_for(content)
      return unchanged if !@manifest.changed_content?(digest) && @manifest.parse_error.blank?

      persist(Vulnerabilities::Parse.call(path: @manifest.path, content: content), digest)
    rescue Vulnerabilities::Parse::Error => e
      # Un lockfile illeggibile è un dato del manifest, non un guasto della scansione: gli altri
      # manifest del progetto devono continuare.
      unverified(e.message, AppError.new("Lockfile illeggibile: #{e.message}", code: "R422-VULN-003"))
    rescue Github::Client::Error => e
      unverified("github:#{e.code}", AppError.new(e.message, code: e.code, status: e.status))
    end

    private

    def fetch(repository)
      return nil if @manifest.blob_sha.blank?

      @client.blob(repository.installation.installation_id, repository.full_name, @manifest.blob_sha)
    end

    def unchanged
      @manifest.update!(scanned_at: @now)
      Result.ok(@manifest.packages.to_a)
    end

    def persist(dependencies, digest)
      packages = nil

      ApplicationRecord.transaction do
        packages = reconcile(dependencies)
        @manifest.update!(content_digest: digest, scanned_at: @now, parse_error: nil,
                          packages_count: packages.size)
      end

      @manifest.packages.reset
      Result.ok(packages)
    end

    # Allinea i pacchetti a ciò che il lockfile dichiara ADESSO, per identità stabile nome+versione
    # dentro il manifest — la stessa chiave su cui il database garantisce l'unicità.
    #
    # Sostituire in blocco sarebbe una riga sola, ma il finding pende dal pacchetto: cancellare e
    # ricreare una riga IDENTICA le darebbe un id nuovo, e con lui una vulnerabilità che riparte da
    # zero — senza la decisione di ignorarla, senza la prima rilevazione, senza il ticket collegato.
    # Bastava che cambiasse un'altra dipendenza dello stesso file (CYRA-811).
    def reconcile(dependencies)
      rows = dependencies.uniq { |dependency| [ dependency.name, dependency.version ] }
      known = @manifest.packages.index_by { |package| [ package.name, package.version ] }

      packages = rows.map do |dependency|
        existing = known.delete([ dependency.name, dependency.version ])
        existing ? keep(existing, dependency) : add(dependency)
      end

      # Resta solo ciò che il lockfile non dichiara più. Un aggiornamento di versione è una coppia
      # diversa: quella vecchia esce di qui, e con lei la vulnerabilità che portava (cascade sul
      # finding), perché quella versione non è più installata.
      known.each_value(&:destroy!)
      packages
    end

    # Stessa riga, dati aggiornabili: una dipendenza può passare da transitiva a dichiarata senza
    # cambiare versione. Si scrive solo se qualcosa è davvero cambiato — un update a vuoto per ogni
    # pacchetto di ogni lockfile a ogni scansione è lavoro che non dice nulla.
    def keep(package, dependency)
      attributes = { ecosystem: @manifest.ecosystem, direct: dependency.direct? }
      changed = attributes.reject { |name, value| package.public_send(name) == value }
      package.update!(changed) if changed.any?
      package
    end

    def add(dependency)
      @manifest.packages.create!(name: dependency.name, version: dependency.version,
                                 ecosystem: @manifest.ecosystem, direct: dependency.direct?)
    end

    def missing_repository
      AppError.new("Il progetto non ha un repository GitHub collegato", code: "R422-VULN-002")
    end

    def missing_blob
      AppError.new("Contenuto del lockfile non disponibile", code: "R404-VULN-001", status: :not_found)
    end

    def too_large
      AppError.new("Lockfile oltre la dimensione massima", code: "R422-VULN-004")
    end

    # Ogni modo di NON leggere un lockfile lascia lo stesso segno: il motivo su `parse_error` e il
    # tentativo su `scanned_at`. Prima lo lasciavano solo il parser e il tetto di dimensione, e un
    # blob sparito o un GitHub muto erano indistinguibili da una lettura riuscita a vuoto — cioè da
    # un file senza vulnerabilità (CYRA-810). È questo segno il perimetro che la riconciliazione dei
    # finding deve lasciare stare.
    def unverified(reason, error)
      @manifest.update!(parse_error: reason.to_s.first(120), scanned_at: @now)
      Result.err(error)
    end
  end
end
