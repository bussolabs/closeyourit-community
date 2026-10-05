# frozen_string_literal: true

module Knowledge
  module Review
    # Le regole che si verificano SENZA il modello: regex e confronti, in Ruby, prima di pagare la
    # latenza di una chiamata al server AI di casa. Puro come PlainLanguageCheck: riceve testi,
    # ritorna un Array<Violation>. I titoli con cui confrontare wikilink e serie multi-parte li passa
    # il chiamante (`known_titles`), così qui non c'è DB.
    #
    # La numerazione delle regole (K = comuni, P = procedura, A = accessi di test) è quella di
    # app/prompts/knowledge/review.md e di knowledge-base/global/knowledge-formats.md.
    class Precheck
      FORMAT_LINE = /\A\s*Formato:\s*(.+?)\s*\z/i
      # `<Area> — <oggetto>` con il trattino LUNGO (U+2014) circondato da spazi: è la forma della
      # knowledge base versionata e l'unica che il revisore riconosce.
      TITLE = /\A\S.{0,80}? — \S.+\z/
      OTHER_DASHES = /\A\S.{0,80}? [-–] \S.+\z/
      # «Tre trappole», «quattro cose», «due muri»: il titolo di una pagina che ne impacchetta
      # parecchie (24 su 598 nell'analisi del 2026-09-02).
      BUNDLE_TITLE = /\b(due|tre|quattro|cinque|sei|\d+)\s+(trappole|cose|muri|problemi|difetti|casi|errori)\b/i
      PART = /\s\(parte (\d+)\/(\d+)\)\z/
      # Un indirizzo o una mail scritti «a voce» per non scriverli davvero: non si cercano e non si
      # copiano (regola K07).
      SPELLED_OUT = /\S+ punto \S+ punto \S+|\S+ chiocciola \S+/i
      # Segreti (regola K08). L'URL con credenziali si blocca sempre; i prefissi noti delle chiavi e
      # la coppia `nome = valore` solo fuori dal formato «accessi di test», dove le password ci
      # DEVONO stare (regola A03).
      CREDENTIALS_URL = %r{\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s@]+@}i
      KNOWN_KEY_PREFIXES = /\b(sk-[A-Za-z0-9]{8,}|ghp_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|AKIA[A-Z0-9]{12,}|xox[abp]-[A-Za-z0-9-]{8,})\b|-----BEGIN [A-Z ]*PRIVATE KEY-----/
      KEY_VALUE = /\b(api[_-]?key|secret|token|password|passwd)\b\s*[:=]\s*["'`]?[^\s"'`]{8,}/i
      PRODUCTION_ENVIRONMENT = /^\s*Ambiente:\s*(production|produzione|prod)\b/i
      ENVIRONMENT_LINE = /^\s*Ambiente:\s*(staging|development|dev|sviluppo|prova|test)\b/i

      def self.call(...) = new(...).call

      # `legacy: true` (CYRA-773): il giro sul parco scritto PRIMA delle regole di forma. Le regole di
      # sola forma — riga `Formato:` (K01) e tag (K11) — non contano, e il titolo fuori schema (K02) è
      # un avviso: a metterle in regola ci pensa Knowledge::Review::Normalize dopo il verdetto. Il
      # modello deduce il formato dal contenuto. Le regole di sostanza restano tutte.
      def initialize(title:, body:, tech_spec:, kind:, tags:, known_titles: [], legacy: false)
        @legacy = legacy
        @title = title.to_s.strip
        @body = body.to_s
        @tech_spec = tech_spec.to_s
        @kind = kind.to_s
        # Normalizzati come Knowledge::Page (strip/downcase/uniq): «Rails» e «rails» sono un tag solo.
        @tags = Array(tags).map { |tag| tag.to_s.strip.downcase }.reject(&:blank?).uniq
        @known_titles = Array(known_titles).map(&:to_s)
      end

      # Il formato dichiarato nella prima riga (chiave dell'enum), o nil.
      def self.format_of(body)
        first_line = body.to_s.lines.map(&:strip).find(&:present?)
        declared = first_line.to_s[FORMAT_LINE, 1]&.downcase
        return nil unless declared

        Knowledge::Constants::REVIEW_FORMATS.find do |key|
          declared == key || declared == Knowledge::Constants::REVIEW_FORMAT_LABELS[key]
        end
      end

      def call
        violations = []
        check_format(violations)
        check_title(violations)
        check_spelled_out(violations)
        check_secrets(violations)
        check_kind(violations)
        check_tags(violations)
        check_lengths(violations)
        check_parts(violations)
        check_wikilinks(violations)
        violations
      end

      private

      def format = @format ||= self.class.format_of(@body)

      def text = "#{@body}\n#{@tech_spec}"

      # Per i segreti (K08) si guarda TUTTO ciò che viene salvato: anche titolo e tag.
      def everything = "#{@title}\n#{@tags.join(' ')}\n#{text}"

      def add(violations, code, blocking: true, **args)
        violations << Violation.new(code: code, message: I18n.t("member.knowledge.review_rules.#{code}", **args), blocking: blocking)
      end

      def check_format(violations)
        return if @legacy

        add(violations, "K01", formats: Knowledge::Constants::REVIEW_FORMAT_LABELS.values.join(", ")) unless format
      end

      def check_title(violations)
        if !@title.match?(TITLE)
          add(violations, @title.match?(OTHER_DASHES) ? "K02_dash" : "K02", blocking: !@legacy)
        elsif @title.match?(BUNDLE_TITLE)
          add(violations, "K02_bundle")
        end
      end

      def check_spelled_out(violations)
        add(violations, "K07") if text.match?(SPELLED_OUT)
      end

      def check_secrets(violations)
        add(violations, "K08_url") if everything.match?(CREDENTIALS_URL)
        if format == "test_access"
          add(violations, "A01") if text.match?(PRODUCTION_ENVIRONMENT)
          add(violations, "A01_missing") unless text.match?(PRODUCTION_ENVIRONMENT) || text.match?(ENVIRONMENT_LINE)
        else
          add(violations, "K08_key") if everything.match?(KNOWN_KEY_PREFIXES) || everything.match?(KEY_VALUE)
        end
      end

      def check_kind(violations)
        expected = Knowledge::Constants::REVIEW_FORMAT_KINDS[format]
        return if expected.nil? || expected == @kind

        add(violations, "K10", expected: expected, format_name: Knowledge::Constants::REVIEW_FORMAT_LABELS[format])
      end

      def check_tags(violations)
        return if @legacy

        add(violations, "K11", min: Knowledge::Constants::REVIEW_MIN_TAGS) if @tags.size < Knowledge::Constants::REVIEW_MIN_TAGS
      end

      def check_lengths(violations)
        add(violations, "K12_body", max: Knowledge::Constants::BODY_MAX_CHARS) if @body.length > Knowledge::Constants::BODY_MAX_CHARS
        if @tech_spec.length > Knowledge::Constants::TECH_SPEC_MAX_CHARS
          add(violations, "K12_tech", max: Knowledge::Constants::TECH_SPEC_MAX_CHARS)
        elsif @tech_spec.length > Knowledge::Constants::REVIEW_TECH_SPEC_SQUEEZED_CHARS
          add(violations, "K12_squeezed")
        end
      end

      # Regola P05: `Base (parte N/M)`. N e M sensati, la stessa Base e la stessa M nelle altre parti
      # già presenti; una parte che ancora manca è un avviso, non un blocco.
      def check_parts(violations)
        match = @title.match(PART)
        return unless match

        current, total = match[1].to_i, match[2].to_i
        return add(violations, "P05_numbers") if current < 1 || total < 2 || current > total

        base = @title.sub(PART, "")
        siblings = @known_titles.filter_map { |t| (m = t.match(PART)) && t.sub(PART, "") == base ? [ m[1].to_i, m[2].to_i ] : nil }
        return add(violations, "P05_total") if siblings.any? { |_, other_total| other_total != total }

        present = siblings.map(&:first) << current
        missing = (1..total).to_a - present
        add(violations, "P05_missing", missing: missing.join(", "), blocking: false) if missing.any?
      end

      # Regola K14: ogni `[[Titolo]]` deve esistere. La parte successiva di una serie non esiste
      # ancora quando si scrive la precedente: per quella è un avviso.
      def check_wikilinks(violations)
        known = @known_titles.map(&:downcase)
        own_base = @title.sub(PART, "")
        Knowledge::Links::Parse.call(text: @body).each do |reference|
          next if known.include?(reference.title.downcase) || reference.title.casecmp?(@title)

          same_series = reference.title.match?(PART) && reference.title.sub(PART, "") == own_base
          add(violations, "K14", title: reference.title, blocking: !same_series)
        end
      end
    end
  end
end
