# frozen_string_literal: true

module Vulnerabilities
  # Registry STATICO degli ecosistemi di pacchetti che sappiamo leggere, nella nomenclatura esatta di
  # OSV.dev (`RubyGems`, `npm`, `Pub`, `Go`): il nome è il valore che finisce nella query, non
  # un'etichetta nostra. Aggiungerne uno richiede codice — un parser — quindi è una costante e non una
  # tabella, stesso criterio di Monitoring::Tool.
  #
  # `MANIFESTS` mappa il NOME FILE (non il path) all'ecosistema: è ciò che permette di scoprire i
  # lockfile dal tree di un repository senza indovinarne la posizione, che in un monorepo non è nota.
  module Ecosystem
    RUBYGEMS = "RubyGems"
    NPM = "npm"
    PUB = "Pub"
    GO = "Go"

    ALL = [ RUBYGEMS, NPM, PUB, GO ].freeze

    MANIFESTS = {
      "Gemfile.lock" => RUBYGEMS,
      "pnpm-lock.yaml" => NPM,
      "package-lock.json" => NPM,
      "pubspec.lock" => PUB,
      "go.sum" => GO
    }.freeze

    # Directory che contengono copie di dipendenze o di altri branch: i loro lockfile non
    # descrivono ciò che il progetto usa davvero e gonfierebbero la scansione con doppioni.
    IGNORED_PATH_SEGMENTS = %w[node_modules vendor worktrees .git tmp fixtures].freeze

    def self.for_path(path) = MANIFESTS[File.basename(path.to_s)]

    def self.manifest?(path) = for_path(path).present?

    def self.ignored_path?(path)
      segments = path.to_s.split("/")[0...-1]
      segments.any? { |segment| IGNORED_PATH_SEGMENTS.include?(segment) }
    end

    # Un path è scansionabile se è un lockfile noto e non vive in una directory da ignorare.
    def self.scannable?(path) = manifest?(path) && !ignored_path?(path)
  end
end
