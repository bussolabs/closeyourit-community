# frozen_string_literal: true

require "digest"

module Secrets
  module Consolidation
    # Cosa succede davvero se questa proposta viene accettata (CYRA-777), e l'impronta di quel «cosa».
    #
    # Stessa idea di Secrets::Shared::Impact — la conferma vale su ciò che si è VISTO — con un
    # confine preciso: il digest copre lo stato del mondo (quali progetti, quali variabili, quale
    # valore, se l'organizzazione lo tiene già), NON le scelte di chi conferma. Il nome del secret
    # dell'organizzazione e gli alias arrivano dal form e possono cambiare fin sull'ultimo clic: se
    # entrassero nel digest, cambiare una lettera nel nome farebbe rispondere «conferma obsoleta» a
    # una richiesta perfettamente valida, e la protezione diventerebbe un ostacolo da aggirare.
    #
    # Quello che deve invalidare la conferma è l'altro caso: fra la pagina e il clic un terzo progetto
    # ha preso lo stesso valore, o uno dei due l'ha cambiato. Lì si sta per scrivere su un mondo
    # diverso da quello letto, e si rilegge.
    class Impact < ApplicationService
      def initialize(suggestion:)
        @suggestion = suggestion
      end

      def call
        candidate = current_candidate
        payload = {
          # L'id della proposta, NON l'impronta: l'impronta non esce mai dal database — non in API,
          # non in pagina, non nei log, non negli eventi (decisione del 2026-09-04). Identifica la
          # stessa cosa, visto che una proposta è unica per [organizzazione, ambiente, valore].
          "suggestion_id" => @suggestion.id,
          "environment" => @suggestion.environment.code,
          # nil quando l'organizzazione non tiene ancora quel valore: entra nel digest perché cambia
          # la natura dell'operazione (delegare quello che c'è, invece di crearne uno nuovo).
          "shared_value_id" => candidate&.shared_value&.id,
          "projects" => projects_payload(candidate)
        }
        Result.ok(payload.merge("digest" => Digest::SHA256.hexdigest(payload.to_json)))
      end

      private

      # Il candidato RICALCOLATO adesso, mai i conteggi salvati sulla proposta: quelli sono la
      # fotografia dell'ultimo giro del job, e qui si sta per scrivere.
      def current_candidate
        @current_candidate ||= Candidates.call(
          organization: @suggestion.organization, environment: @suggestion.environment,
          fingerprints: [ @suggestion.value_fingerprint ]
        ).value.first
      end

      def projects_payload(candidate)
        return [] if candidate.nil?

        candidate.variables.map do |variable|
          repository = variable.project.github_repository
          {
            "project_id" => variable.project_id,
            "project" => variable.project.name,
            "name" => variable.name,
            "repository" => repository&.sync_secrets? ? repository.full_name : nil
          }
        end.sort_by { |row| [ row["project"].to_s.downcase, row["name"].to_s ] }
      end
    end
  end
end
