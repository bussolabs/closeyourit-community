# frozen_string_literal: true

module Seo
  # Registro STATICO dei controlli che sappiamo fare su una pagina o su un sito. Catalogo
  # dev-defined → COSTANTE, non tabella CRUD (eccezione enum-static di rules/lookup-tables.md:
  # aggiungere un controllo significa scrivere il codice che lo esegue, non inserire una riga).
  # Stessa natura di Monitoring::Tool e Navigation::Group.
  #
  # Ogni voce dichiara:
  #   severity — quanto pesa di default. Finisce COPIATA su Seo::Issue alla creazione, così
  #              l'ordinamento è una colonna e non un join, e un cambio di listino qui non riscrive
  #              la storia: i rilievi vecchi si allineano quando la scansione li riconferma.
  #   area     — come si legge l'elenco: indexability | structure | content | i18n | performance.
  #   scope    — :page  il controllo guarda una pagina sola;
  #              :site  il controllo esiste solo confrontando le pagine fra loro (duplicati,
  #                     orfane, hreflang non reciproci) e non ha una `page_id`.
  #   needs    — quanto bisogna essere riusciti a osservare la pagina (o il giro, per i controlli
  #              d'insieme) perché questo controllo si possa dire ESEGUITO (CYRA-808):
  #                :attempted  basta averci provato — sappiamo se robots.txt la vieta;
  #                :responded  il server ha risposto: sappiamo stato, catena di salti e tempo;
  #                :analyzed   la risposta era HTML e l'abbiamo letta: sappiamo cosa c'è dentro.
  #              Serve alla riconciliazione, non all'esecuzione: un rilievo si chiude solo se il
  #              giro ha davvero potuto guardare quella cosa. Senza, un timeout equivarrebbe a una
  #              verifica riuscita e l'elenco dei problemi migliorerebbe proprio quando il controllo
  #              peggiora. Il verso è asimmetrico di proposito: per APRIRE basta l'osservazione che
  #              lo dimostra (un `redirect_loop` si vede senza mai ricevere una risposta), per
  #              CHIUDERE serve la prova piena.
  #
  # Etichetta e spiegazione stanno in i18n (`seo.checks.<key>.*`, rules/i18n.md); qui vive solo la
  # struttura. La spiegazione non è decorazione: un rilievo che non dice perché conta è rumore.
  class Check
    AREAS = %w[indexability structure content i18n performance].freeze
    SEVERITIES = %i[low medium high critical].freeze

    REGISTRY = {
      # --- indexability: il motore di ricerca può vedere e tenere questa pagina? ----------------
      "noindex" => { severity: :critical, area: "indexability", scope: :page, needs: :analyzed },
      "blocked_by_robots" => { severity: :critical, area: "indexability", scope: :page, needs: :attempted },
      "broken_link" => { severity: :high, area: "indexability", scope: :page, needs: :responded },
      "redirect_loop" => { severity: :critical, area: "indexability", scope: :page, needs: :responded },
      "redirect_chain" => { severity: :medium, area: "indexability", scope: :page, needs: :responded },
      "canonical_missing" => { severity: :low, area: "indexability", scope: :page, needs: :analyzed },
      "canonical_points_elsewhere" => { severity: :high, area: "indexability", scope: :page, needs: :analyzed },
      "sitemap_unreachable" => { severity: :high, area: "indexability", scope: :site, needs: :attempted },
      "robots_unreachable" => { severity: :medium, area: "indexability", scope: :site, needs: :attempted },
      "missing_from_sitemap" => { severity: :low, area: "indexability", scope: :page, needs: :analyzed },
      # Raggiungibile solo dalla sitemap: nessuna pagina del sito la linka. Chi arriva dal menu non
      # la troverà mai, e il motore le dà il peso che le danno i link — cioè nessuno.
      "orphan_page" => { severity: :medium, area: "indexability", scope: :page, needs: :analyzed },

      # --- structure: la pagina si presenta con i pezzi che servono? -----------------------------
      "missing_title" => { severity: :critical, area: "structure", scope: :page, needs: :analyzed },
      "title_too_long" => { severity: :low, area: "structure", scope: :page, needs: :analyzed },
      "duplicate_title" => { severity: :medium, area: "structure", scope: :site, needs: :analyzed },
      "missing_meta_description" => { severity: :medium, area: "structure", scope: :page, needs: :analyzed },
      "duplicate_meta_description" => { severity: :low, area: "structure", scope: :site, needs: :analyzed },
      # Il caso che giustifica l'intero cockpit: un punteggio verde di Lighthouse non si accorge di
      # una pagina senza h1, perché quel controllo Lighthouse non lo fa.
      "missing_h1" => { severity: :high, area: "structure", scope: :page, needs: :analyzed },
      "multiple_h1" => { severity: :low, area: "structure", scope: :page, needs: :analyzed },
      "missing_jsonld" => { severity: :low, area: "structure", scope: :page, needs: :analyzed },

      # --- i18n: il sito multilingua si dichiara bene? -------------------------------------------
      "lang_missing" => { severity: :medium, area: "i18n", scope: :page, needs: :analyzed },
      "hreflang_not_reciprocal" => { severity: :medium, area: "i18n", scope: :site, needs: :analyzed },
      "hreflang_missing_x_default" => { severity: :low, area: "i18n", scope: :site, needs: :analyzed },

      # --- content ------------------------------------------------------------------------------
      "thin_content" => { severity: :medium, area: "content", scope: :page, needs: :analyzed },
      "images_without_alt" => { severity: :low, area: "content", scope: :page, needs: :analyzed },

      # --- performance: misurato dal nostro fetch, non dal campo (niente CWV in v1) --------------
      "slow_response" => { severity: :medium, area: "performance", scope: :page, needs: :responded },
      "oversized_html" => { severity: :low, area: "performance", scope: :page, needs: :analyzed },
      "mixed_content" => { severity: :high, area: "performance", scope: :page, needs: :analyzed }
    }.freeze

    # Soglie dei controlli che ne hanno una. Stanno qui e non sparse nei servizi: sono la parte che
    # si discute, e vanno lette in un posto solo.
    THRESHOLDS = {
      title_max_length: 60,
      thin_content_words: 150,
      slow_response_ms: 1_500,
      oversized_html_bytes: 500_000,
      max_redirect_hops: 1
    }.freeze

    # I livelli di osservazione, dal più povero al più ricco (CYRA-808). L'ordine È il significato:
    # chi è arrivato ad `analyzed` sa anche tutto quello che sa chi si è fermato a `responded`.
    OBSERVATIONS = %i[attempted responded analyzed].freeze

    FALLBACK_SEVERITY = :medium
    FALLBACK_AREA = "structure"
    # Un controllo fuori registro pretende la prova più forte: chi non si conosce non si chiude a
    # occhi chiusi.
    FALLBACK_NEEDS = :analyzed
    # Un fatto senza livello dichiarato vale come il minimo: non chiude quasi niente. Il contrario
    # — dare per letto ciò che nessuno ha dichiarato di aver letto — è il guasto stesso.
    FALLBACK_OBSERVATION = :attempted

    def self.keys = REGISTRY.keys
    def self.all = keys.map { |key| new(key) }
    def self.known?(key) = REGISTRY.key?(key.to_s)
    def self.find(key) = known?(key) ? new(key.to_s) : nil
    def self.for_area(area) = all.select { |check| check.area == area.to_s }
    def self.page_scoped = all.select(&:page_scoped?)
    def self.site_scoped = all.select(&:site_scoped?)
    def self.threshold(name) = THRESHOLDS.fetch(name)

    # Il livello dichiarato da un fatto del crawl, ricondotto al vocabolario: qualunque cosa non
    # riconosca vale come «ci ho solo provato».
    def self.observation(value)
      OBSERVATIONS.include?(value&.to_sym) ? value.to_sym : FALLBACK_OBSERVATION
    end

    # Il più ricco fra due livelli: serve al giro, che vale quanto la pagina che gli è riuscita
    # meglio (i controlli d'insieme confrontano le pagine fra loro, e una basta a renderli possibili).
    def self.richest_observation(values)
      values.map { |value| observation(value) }.max_by { |level| OBSERVATIONS.index(level) } ||
        FALLBACK_OBSERVATION
    end

    attr_reader :key

    def initialize(key)
      @key = key.to_s
    end

    def known? = self.class.known?(key)
    def severity = REGISTRY.dig(key, :severity) || FALLBACK_SEVERITY
    def area = REGISTRY.dig(key, :area) || FALLBACK_AREA
    def scope = REGISTRY.dig(key, :scope) || :page
    def page_scoped? = scope == :page
    def site_scoped? = scope == :site
    def needs = REGISTRY.dig(key, :needs) || FALLBACK_NEEDS

    # Con questo livello di osservazione, il controllo si può dire ESEGUITO? È la domanda che decide
    # se un rilievo che non è più comparso è sparito davvero o solo smesso di guardare (CYRA-808).
    def verifiable_with?(observation)
      reached = OBSERVATIONS.index(self.class.observation(observation))
      reached >= OBSERVATIONS.index(needs)
    end

    # Visibili all'utente via i18n; default = key così un controllo ignoto resta leggibile invece di
    # comparire come riga vuota.
    def label = I18n.t("seo.checks.#{key}.label", default: key)
    def explanation = I18n.t("seo.checks.#{key}.explanation", default: "")

    def ==(other) = other.is_a?(Check) && other.key == key
    alias_method :eql?, :==
    def hash = key.hash
  end
end
