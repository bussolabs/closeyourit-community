# frozen_string_literal: true

module Agents
  # CYRA-453 — «il rilascio è arrivato ovunque?»: la domanda che motiva il pin del bundle skill, e a
  # cui la pagina non rispondeva. Dichiarava la versione fissata e taceva su quale versione stesse
  # davvero girando su ciascuna macchina — leggibile solo aprendo il dettaglio di ogni agente, uno
  # per uno.
  #
  # La versione FISSATA è il pin (`Agents::SkillBundle#version`). La versione IN USO si legge dallo
  # snapshot che ogni host manda col battito (`runtimes`), che è TESTO LIBERO deciso dal client: il
  # nome del programma («skills», «closeyourit-skills», «CloseYourIt Skills») e la versione, che può
  # arrivare discorsiva («@bussolabs/closeyourit-skills/0.15.0»).
  #
  # Da qui la regola di prudenza, che è il cuore di questa classe: ciò che non si sa leggere resta
  # `:unknown`. Un parser severo trasformerebbe ogni dichiarazione fuori formato in un falso
  # disallineamento, e una tabella che grida al lupo su macchine sane non la guarda più nessuno.
  class SkillBundleConformance
    # aligned    = la macchina dichiara la stessa versione fissata
    # mismatched = ne dichiara una diversa (più vecchia o più nuova: la pagina dice solo «non combacia»)
    # unknown    = non c'è un pin, oppure la macchina non dichiara nulla di leggibile
    Row = Data.define(:host, :expected, :actual, :state) do
      def aligned? = state == :aligned
      def mismatched? = state == :mismatched
      def unknown? = state == :unknown
    end

    # Un numero di versione dentro una stringa qualunque: «0.3.0», «v1.2.0», «…/0.15.0», «2.0.0-rc.1».
    # Almeno un punto di proposito: un «22» isolato in una frase non è una versione riconoscibile.
    VERSION = /\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?/

    def initialize(bundle:, hosts:)
      @bundle = bundle
      @hosts = hosts
    end

    def rows
      @rows ||= @hosts.sort_by { |host| host.hostname.to_s.downcase }.map { |host| row_for(host) }
    end

    def aligned_count = rows.count(&:aligned?)
    def mismatched_count = rows.count(&:mismatched?)
    def unknown_count = rows.count(&:unknown?)
    def any? = rows.any?

    private

    def row_for(host)
      actual = declared_version(host)
      Row.new(host: host, expected: expected_version, actual: actual, state: state_for(actual))
    end

    def state_for(actual)
      return :unknown if expected_version.nil? || actual.nil?

      actual == expected_version ? :aligned : :mismatched
    end

    def expected_version
      return @expected_version if defined?(@expected_version)

      @expected_version = extract_version(@bundle&.version)
    end

    # Il programma delle competenze fra tutti quelli dichiarati dalla macchina: riconosciuto per nome
    # (contiene «skill») o perché coincide col nome del repository pinnato, così un repository
    # chiamato diversamente resta comunque riconoscibile. `present: false` = non installato: nessuna
    # versione da leggere.
    def declared_version(host)
      runtime = host.runtimes.find do |candidate|
        candidate.is_a?(Hash) && candidate["present"] != false && skill_runtime?(candidate["name"])
      end
      extract_version(runtime && runtime["version"])
    end

    def skill_runtime?(name)
      normalized = name.to_s.downcase
      normalized.include?("skill") || (repo_name.present? && normalized == repo_name)
    end

    def repo_name
      return @repo_name if defined?(@repo_name)

      @repo_name = @bundle&.repo.to_s.split("/").last.to_s.downcase
    end

    def extract_version(raw) = raw.to_s[VERSION]
  end
end
