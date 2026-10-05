# frozen_string_literal: true

module Secrets
  module Consolidation
    # Porta i fatti trovati da Candidates dentro la tabella delle proposte, applicandoci sopra la
    # memoria delle decisioni già prese (CYRA-777).
    #
    # Le quattro regole, che sono tutto il servizio:
    #
    #   proposta nuova     → nasce aperta e avvisa chi tiene i secret dell'organizzazione, UNA volta.
    #   proposta aperta    → si aggiornano i conteggi e il nome proposto; nessuna seconda notifica.
    #   «non proporre più» → non si tocca. È l'unica decisione che il giro notturno non può revocare:
    #                        se il valore ripetuto tornasse a proporsi, il pulsante non varrebbe niente.
    #   già accettata      → si RIAPRE se il valore è tornato a essere ricopiato a mano in due o più
    #                        progetti. Il fatto è di nuovo vero, e il secret dell'organizzazione nato
    #                        la prima volta resta lì da riusare invece di crearne un secondo.
    #
    # E una quinta che vale al contrario: una proposta aperta che NON è più un candidato — qualcuno ha
    # cambiato uno dei due valori, o cancellato una delle due variabili — sparisce. Non c'è più niente
    # da proporre e non c'è nessuna decisione umana da conservare.
    class Refresh < ApplicationService
      Outcome = Data.define(:created, :updated, :reopened, :closed)

      # `environment:` e `fingerprints:` restringono TUTTO il giro, chiusura delle proposte sparite
      # compresa: il refresh mirato che segue un salvataggio non deve poter cancellare proposte di
      # ambienti che non ha nemmeno guardato.
      def initialize(organization:, environment: nil, fingerprints: nil)
        @organization = organization
        @environment = environment
        @fingerprints = fingerprints.presence && Array(fingerprints).compact
        @created = []
        @updated = 0
        @reopened = []
      end

      def call
        candidates = Candidates.call(organization: @organization, environment: @environment,
                                     fingerprints: @fingerprints).value
        candidates.each { |candidate| apply(candidate) }
        closed = close_disappeared(candidates)

        # Le notifiche partono DOPO le scritture: una consegna che fallisce non deve lasciare a metà
        # la tabella delle proposte.
        (@created + @reopened).each { |suggestion| Notifications::DispatchConsolidationSuggested.call(suggestion:) }

        Result.ok(Outcome.new(created: @created.size, updated: @updated, reopened: @reopened.size, closed:))
      end

      private

      def apply(candidate)
        suggestion = find_or_create(candidate)
        return if suggestion.nil? || suggestion.status_dismissed?

        if suggestion.status_promoted?
          reopen(suggestion, candidate)
        elsif suggestion.persisted?
          refresh_open(suggestion, candidate)
        end
      end

      # Il vincolo di unicità è la difesa vera contro due giri concorrenti sullo stesso valore: se
      # perde la corsa, rilegge la riga scritta dall'altro invece di sollevare.
      def find_or_create(candidate)
        existing = scope.find_by(environment_id: candidate.environment.id,
                                 value_fingerprint: candidate.value_fingerprint)
        return existing if existing

        created = Suggestion.create!(organization: @organization, environment: candidate.environment,
                                     value_fingerprint: candidate.value_fingerprint,
                                     suggested_name: candidate.suggested_name,
                                     projects_count: candidate.projects_count,
                                     first_seen_at: Time.current, last_seen_at: Time.current)
        @created << created
        created
      rescue ActiveRecord::RecordNotUnique
        scope.find_by(environment_id: candidate.environment.id, value_fingerprint: candidate.value_fingerprint)
      end

      def refresh_open(suggestion, candidate)
        suggestion.update!(projects_count: candidate.projects_count,
                           suggested_name: candidate.suggested_name,
                           last_seen_at: Time.current)
        @updated += 1
      end

      # `first_seen_at` riparte: in «Da sistemare» la riga dice «da quando», e la data della prima
      # volta racconterebbe una proposta vecchia mesi che invece è appena tornata vera.
      def reopen(suggestion, candidate)
        suggestion.update!(status: :open, promoted_at: nil, promoted_by: nil,
                           projects_count: candidate.projects_count,
                           suggested_name: candidate.suggested_name,
                           first_seen_at: Time.current, last_seen_at: Time.current)
        @reopened << suggestion
      end

      def close_disappeared(candidates)
        alive = candidates.map { |candidate| [ candidate.environment.id, candidate.value_fingerprint ] }.to_set
        vanished = scope.status_open.to_a.reject do |suggestion|
          alive.include?([ suggestion.environment_id, suggestion.value_fingerprint ])
        end
        vanished.each(&:destroy!)
        vanished.size
      end

      def scope
        base = Suggestion.where(organization_id: @organization.id)
        base = base.where(environment_id: @environment.id) if @environment
        base = base.where(value_fingerprint: @fingerprints) if @fingerprints
        base
      end
    end
  end
end
