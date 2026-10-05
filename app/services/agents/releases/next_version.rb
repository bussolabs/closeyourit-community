# frozen_string_literal: true

module Agents
  module Releases
    # CYRA-621 — la regola con cui il SERVER sceglie il numero. È scritta, ed è sempre la stessa.
    #
    # Si parte dall'ultimo numero stabile DAVVERO presente nel deposito del codice, chiesto sul
    # momento a chi lo sa. Non da quello che la macchina si ricorda, e nemmeno dall'archivio interno
    # delle versioni, che su sette progetti su otto è vuoto — leggerlo lì vorrebbe dire ripartire da
    # zero su quasi tutti i progetti.
    #
    # Poi: solo correzioni di difetti → cambia l'ultima cifra; anche una novità o un lavoro nuovo →
    # cambia la cifra di mezzo e azzera l'ultima. La prima cifra non si cambia mai da sola: quello
    # resta un salto che decide una persona, e indovinarlo sarebbe annunciare una rottura che nessuno
    # ha deciso.
    class NextVersion < ApplicationService
      STABLE = /\Av(\d+)\.(\d+)\.(\d+)\z/
      FIRST_VERSION = "v0.1.0"
      # I kind che valgono come «solo correzione». Tutto il resto alza la cifra di mezzo: fra
      # sbagliare in su e sbagliare in giù, in su è l'errore che non nasconde una novità.
      FIXES_ONLY = %w[bug].freeze

      def initialize(repository:, tickets:, client: nil)
        @repository = repository
        @tickets = tickets
        @client = client
      end

      def call
        baseline = last_stable
        return Result.ok(version: FIRST_VERSION, baseline_tag: nil) if baseline.nil?

        major, minor, patch = STABLE.match(baseline).captures.map(&:to_i)
        next_version = if fixes_only?
                     "v#{major}.#{minor}.#{patch + 1}"
        else
                     "v#{major}.#{minor + 1}.0"
        end
        Result.ok(version: next_version, baseline_tag: baseline)
      rescue Github::Client::Error => e
        # Senza sapere da dove si parte non si sceglie un numero: inventarne uno vorrebbe dire
        # rischiare di riusare un nome già uscito, che è il difetto peggiore che questo pezzo può fare.
        Result.err(AppError.new("Non è stato possibile leggere le versioni già uscite",
                                code: "R409-WORKFLOW-008", status: :conflict, details: { github: e.code }))
      end

      private

      def client = @client ||= Github::Client.new

      # Il più alto fra i tag stabili, confrontati come numeri e non come testo: «v0.9.0» e «v0.10.0»
      # in ordine alfabetico escono al contrario.
      def last_stable
        client.tags(@repository.github_installation_id, @repository.full_name)
              .select { |name| STABLE.match?(name) }
              .max_by { |name| STABLE.match(name).captures.map(&:to_i) }
      end

      def fixes_only?
        list = Array(@tickets)
        list.any? && list.all? { |ticket| FIXES_ONLY.include?(ticket.kind.to_s) }
      end
    end
  end
end
