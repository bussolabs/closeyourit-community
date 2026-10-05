# frozen_string_literal: true

module Vulnerabilities
  # Lettura dei lockfile. Ogni parser è una funzione pura: stringa → elenco di dipendenze risolte.
  # Nessuno tocca il database e nessuno esce in rete — così il confronto con OSV e la persistenza
  # restano testabili senza un lockfile vero, e un lockfile vero è testabile senza database.
  #
  # Il dispatch è sul NOME FILE, non sull'ecosistema: `npm` ha due formati incompatibili
  # (`pnpm-lock.yaml` e `package-lock.json`) che finiscono nello stesso ecosistema OSV.
  module Parse
    # Una dipendenza risolta. `direct` = il progetto la dichiara; false = se la porta dietro.
    Dependency = Data.define(:name, :version, :direct) do
      def initialize(name:, version:, direct: false) = super

      def direct? = direct
    end

    # Il lockfile c'è ma non siamo riusciti a leggerlo. Non è un guasto del sistema: è un dato del
    # manifest (`parse_error`), che resta visibile invece di sparire fingendo "nessuna vulnerabilità".
    class Error < StandardError; end

    PARSERS = {
      "Gemfile.lock" => "Vulnerabilities::Parse::GemfileLock",
      "pnpm-lock.yaml" => "Vulnerabilities::Parse::PnpmLock",
      "package-lock.json" => "Vulnerabilities::Parse::NpmLock",
      "pubspec.lock" => "Vulnerabilities::Parse::PubspecLock",
      "go.sum" => "Vulnerabilities::Parse::GoSum"
    }.freeze

    def self.parser_for(path) = PARSERS[File.basename(path.to_s)]&.constantize

    # Ritorna l'elenco delle dipendenze, o solleva Parse::Error se il file è illeggibile.
    def self.call(path:, content:)
      parser = parser_for(path)
      raise Error, "unsupported_manifest" if parser.nil?

      parser.call(content: content)
    end
  end
end
