# frozen_string_literal: true

module Secrets
  module Consolidation
    # Trova i «valori in comune» (CYRA-777): gruppi di variabili di progetto che, dentro la stessa
    # organizzazione e lo stesso ambiente, portano lo STESSO valore in almeno due progetti diversi.
    #
    # È solo calcolo: non scrive niente, non conosce le proposte già archiviate né le decisioni
    # prese. Quello è mestiere di Secrets::Consolidation::Refresh, che di qui prende i fatti e ci
    # applica sopra la memoria.
    #
    # Il raggruppamento è sull'IMPRONTA, mai sui nomi: il valore è il cardine — due progetti che
    # chiamano `API_KEY` e `CHIAVE_API` la stessa chiave hanno un valore in comune, due progetti che
    # chiamano `DATABASE_URL` due database diversi non ne hanno nessuno.
    class Candidates < ApplicationService
      # Sotto i due progetti non c'è niente da consolidare: un valore che vive in un progetto solo è
      # esattamente dove deve stare.
      MIN_PROJECTS = 2

      # Un gruppo: l'ambiente, l'impronta, le variabili che lo compongono e — se c'è — il valore che
      # l'organizzazione tiene GIÀ con quello stesso contenuto.
      Candidate = Data.define(:organization, :environment, :value_fingerprint, :variables, :shared_value) do
        def projects = variables.map(&:project).uniq.sort_by { |project| project.name.to_s.downcase }
        def projects_count = variables.map(&:project_id).uniq.size
        def names = variables.map(&:name).uniq.sort

        # Il nome proposto per il secret dell'organizzazione: quello che il maggior numero di
        # progetti usa già, così la maggioranza non deve nemmeno accorgersi del cambio. A parità, il
        # primo in ordine alfabetico — la proposta non deve cambiare nome a ogni giro del job.
        def suggested_name
          variables.map(&:name).tally.min_by { |name, count| [ -count, name ] }&.first
        end

        # Il valore l'organizzazione ce l'ha già: la proposta non è creare un secondo secret identico
        # ma delegare quello che esiste.
        def existing_shared? = shared_value.present?
      end

      # `environment:` e `fingerprints:` restringono il giro a ciò che è appena cambiato: il refresh
      # dopo un salvataggio non deve riscandagliare l'intera organizzazione.
      def initialize(organization:, environment: nil, fingerprints: nil)
        @organization = organization
        @environment = environment
        @fingerprints = fingerprints.presence && Array(fingerprints).compact
      end

      def call
        return Result.ok([]) if keys.empty?

        Result.ok(keys.filter_map { |key| build(key) })
      end

      private

      # Prima le sole CHIAVI dei gruppi che superano la soglia, in SQL: caricare tutte le variabili
      # dell'organizzazione per poi scartarne il 99% in Ruby costerebbe l'intero vault in memoria a
      # ogni giro notturno.
      def keys
        @keys ||= scope.group(:environment_id, :value_fingerprint)
                       .having("COUNT(DISTINCT project_id) >= ?", MIN_PROJECTS)
                       .pluck(:environment_id, :value_fingerprint)
      end

      def scope
        base = ::Secrets::Variable.where(organization_id: @organization.id).where.not(value_fingerprint: nil)
        base = base.where(environment_id: @environment.id) if @environment
        base = base.where(value_fingerprint: @fingerprints) if @fingerprints
        base
      end

      def build(key)
        environment_id, fingerprint = key
        rows = variables_by_key[key]
        return nil if rows.blank?

        Candidate.new(organization: @organization, environment: rows.first.environment,
                      value_fingerprint: fingerprint, variables: rows,
                      shared_value: shared_values_by_key[[ environment_id, fingerprint ]])
      end

      # Una query sola per TUTTI i gruppi (la coppia si filtra poi in Ruby: una `IN` su tuple non è
      # portabile e qui i gruppi sono pochi per costruzione). `project`/`environment` precaricati:
      # la proposta li nomina, e senza preload sarebbe una query per riga.
      def variables_by_key
        @variables_by_key ||= ::Secrets::Variable
          .where(organization_id: @organization.id,
                 environment_id: keys.map(&:first).uniq,
                 value_fingerprint: keys.map(&:last).uniq)
          # `github_repository` compreso: l'impatto della proposta dice a quale repository il valore
          # verrà rispedito, e senza preload sarebbe una query per progetto (la guardia letture a
          # raffica di CYRA-747 la ferma prima che diventi un problema in produzione).
          .includes(:environment, project: :github_repository)
          .ordered
          .group_by { |variable| [ variable.environment_id, variable.value_fingerprint ] }
          .slice(*keys)
      end

      # La domanda inversa: questo valore l'organizzazione ce l'ha già sotto un secret suo?
      def shared_values_by_key
        @shared_values_by_key ||= ::Secrets::Shared::Value
          .joins(:shared_variable)
          .includes(:shared_variable)
          .where(secrets_shared_variables: { organization_id: @organization.id })
          .where(environment_id: keys.map(&:first).uniq, value_fingerprint: keys.map(&:last).uniq)
          .index_by { |value| [ value.environment_id, value.value_fingerprint ] }
      end
    end
  end
end
