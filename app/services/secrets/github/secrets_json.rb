# frozen_string_literal: true

require "json"

module Secrets
  module Github
    # Costruisce il secret virtuale SECRETS_JSON per uno slot GitHub Environment senza persisterlo
    # nel vault. La allowlist vive nel repository: secrets-common + file della destination, con la
    # stessa precedenza di Kamal. Sono ammessi soltanto passthrough TARGET=$SOURCE; qualunque comando
    # o sorgente mancante fallisce chiuso per non pubblicare bundle parziali.
    class SecretsJson < ApplicationService
      SECRET_NAME = "SECRETS_JSON"
      RESERVED_NAMES = ::Secrets::Variable::DERIVED_NAMES
      MAX_BYTES = 48_000
      COMMON_PATH = ".kamal/secrets-common"
      DESTINATION_PATHS = {
        "production" => ".kamal/secrets",
        "staging" => ".kamal/secrets.staging",
        "preview" => ".kamal/secrets.preview"
      }.freeze
      PASSTHROUGH = /\A([A-Z][A-Z0-9_]*)\s*=\s*\$([A-Z][A-Z0-9_]*)\z/
      # I file .kamal/secrets ammettono un commento in coda alla riga (`FOO=$BAR   # perché`), ed è
      # una forma che si usa davvero: la riga POSTGRES_PASSWORD di questo repo ce l'aveva, e da sola
      # faceva fallire l'INTERO sync del vault con R422-GITHUB-007 — silenziosamente, perché il job
      # è fire-and-forget. Il taglio è sicuro proprio perché qui il valore ammesso è solo `$NOME`:
      # non esiste un valore legittimo che contenga `#`.
      TRAILING_COMMENT = /\s+#.*\z/

      def initialize(repository:, slot:, bundle:, client:, installation_id:)
        @repository = repository
        @slot = slot
        @bundle = bundle
        @client = client
        @installation_id = installation_id
      end

      def call
        destination_path = DESTINATION_PATHS[@slot]
        return Result.err(error("slot non supportato")) if destination_path.nil?

        files = [ COMMON_PATH, destination_path ].map do |path|
          [ path, @client.repository_file(@installation_id, @repository.full_name, path, ref: @repository.default_branch) ]
        end
        # Ogni file che non si legge va verificato, non solo il caso in cui mancano tutti: se uno dei due
        # sfugge, il bundle nasce a metà — con i passthrough dell'altro soltanto — e nessuno lo dice.
        missing = files.filter_map { |path, content| path if content.nil? }
        if missing.any?
          verdict = unreadable(missing)
          return Result.err(verdict) if verdict
          return Result.ok(nil) if missing.size == files.size
        end

        mappings = {}
        files.each do |path, content|
          next if content.nil?

          parse(content, path, mappings) { |failure| return Result.err(failure) }
        end
        return Result.err(error("nessun passthrough dichiarato")) if mappings.empty?

        missing = mappings.values.uniq.reject { |source| @bundle.key?(source) }.sort
        return Result.err(error("sorgenti mancanti", details: { missing: })) if missing.any?

        # Una sorgente PRESENTE ma null supererebbe il check `missing` e finirebbe come `null` nel JSON.
        # Nel container `jq -r` la trasformerebbe nella stringa "null" (CYRA-213). La stringa vuota
        # esplicita resta invece "" nel JSON ed è valida per configurazioni opzionali.
        unset = mappings.values.uniq.select { |source| @bundle.fetch(source).nil? }.sort
        return Result.err(error("sorgenti senza valore", code: "R422-GITHUB-009", details: { unset: })) if unset.any?

        payload = JSON.generate(mappings.sort.to_h.transform_values { |source| @bundle.fetch(source) })
        return Result.err(error("SECRETS_JSON supera il limite GitHub", code: "R422-GITHUB-008")) if payload.bytesize >= MAX_BYTES

        Result.ok(payload)
      end

      private

      # CYRA-652 — «i file non ci sono» e «non sono riuscito a leggerli» arrivavano qui identici: un
      # nil. Il primo è normale — un repository che Kamal non lo usa — e il bundle non serve. Il
      # secondo è un guasto, e restava muto: nessun bundle scritto, sincronizzazione dichiarata
      # riuscita, e il conto si paga mesi dopo al rilascio, che si ferma perché la cassetta è vuota.
      # Osservato su closeyourit-rails: i due file sono su `main` e il bundle non è mai nato.
      #
      # A separarli è l'albero del ramo, che si legge con un'altra chiamata: se là dentro quei file
      # non compaiono, non ci sono davvero. Se l'albero non si legge, o è troncato — GitHub taglia la
      # lista oltre il suo limite — non si sa, e non sapere non è un permesso di andare avanti.
      # Restituisce l'errore se i path che non si sono letti risultano ESISTENTI nel ramo, altrimenti
      # nil: là non ci sono, e allora non leggerli è la risposta giusta.
      #
      # `git_tree` nil vuol dire ramo assente o repository senza commit (allow_not_found): è lo stato
      # normale di un progetto appena collegato, non un guasto — e in un repository vuoto quei file
      # davvero non ci sono. Un albero TRONCATO invece non dice niente sull'assenza: GitHub taglia la
      # lista oltre il suo limite, e dichiarare assente ciò che non si è visto è il silenzio da cui
      # nasce tutto questo.
      def unreadable(paths)
        tree = @client.git_tree(@installation_id, @repository.full_name, @repository.default_branch)
        return nil if tree.nil?
        return unreadable_error(paths, "elenco del ramo troncato") if tree[:truncated]

        present_paths = tree[:entries].filter_map { |entry| entry["path"] }.to_set
        existing_paths = paths.select { |path| present_paths.include?(path) }
        return nil if existing_paths.empty?

        unreadable_error(existing_paths, "il ramo li elenca ma non si leggono")
      end

      def unreadable_error(paths, reason)
        AppError.new(
          "il bundle dei secret non è stato costruito: #{reason} (#{paths.join(', ')})",
          code: "R422-GITHUB-012", details: { unreadable: paths, slot: @slot }
        )
      end


      def parse(content, path, mappings)
        content.each_line.with_index(1) do |raw, line_number|
          line = raw.strip.sub(TRAILING_COMMENT, "")
          next if line.blank? || line.start_with?("#")

          match = PASSTHROUGH.match(line)
          unless match
            yield error("riga secrets non supportata", details: { path:, line: line_number })
            return
          end

          target, source = match.captures
          if RESERVED_NAMES.include?(target) || RESERVED_NAMES.include?(source)
            yield error("nome bundle derivato non ammesso", details: { path:, line: line_number })
            return
          end

          mappings[target] = source
        end
      end

      def error(message, code: "R422-GITHUB-007", details: nil)
        AppError.new(message, code:, details:)
      end
    end
  end
end
