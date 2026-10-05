# frozen_string_literal: true

module Agents
  module TicketQueues
    # Capability opaca da consegnare insieme allo snapshot della coda. Il client la conserva senza
    # reinterpretarla e la presenta al claim dopo il preflight; firma, purpose e scadenza impediscono
    # di cambiare ticket/scope o riutilizzare indefinitamente una selezione.
    class Selection
      PURPOSE = "agent-ticket-queue-selection"
      VERSION = 3
      DEFAULT_TTL = 5.minutes

      class << self
        # Host-first (CYAU-80): il token è legato a host + execution_phase + profile_digest (non più all'agente).
        # La fase di default è quella pronta per il ticket (Workflow#ready_execution_phase); il claim la ri-valida
        # sotto lock e Acquire deriva TTL/profile_digest dallo stesso PhaseProfile.
        def issue(ticket:, host:, execution_phase: ticket.agent_workflow&.ready_execution_phase,
                  expires_in: DEFAULT_TTL, estimated_cost: estimated_cost_for(ticket:))
          repository = ticket.project.github_repository
          raise ArgumentError, "ticket senza repository" unless repository
          raise ArgumentError, "host fuori organizzazione" unless host.organization_id == ticket.project.organization_id
          raise ArgumentError, "execution_phase sconosciuta" unless Agents::PhaseProfile.known?(execution_phase)

          canonical_cost = Agents::Limits::Cost.dump(estimated_cost)
          raise ArgumentError, "costo stimato non valido" if estimated_cost && canonical_cost.nil?

          verifier.generate(payload(ticket:, host:, execution_phase:, repository:, estimated_cost: canonical_cost),
                            expires_in:, purpose: PURPOSE)
        end

        # Non esiste oggi una fonte server-side attendibile: weight misura complessità, non denaro.
        # Il nil esplicito permette al claim di fallire chiuso se una policy monetaria è attiva.
        def estimated_cost_for(ticket:)
          nil
        end

        def verify(token)
          return unless token.is_a?(String) && token.present?

          value = verifier.verified(token, purpose: PURPOSE)
          token_version = value["version"] || value[:version] if value.is_a?(Hash)
          value.deep_symbolize_keys if value.is_a?(Hash) && token_version == VERSION
        rescue ActiveSupport::MessageVerifier::InvalidSignature
          nil
        end

        def valid_payload?(selection)
          return false unless selection

          required = %i[organization_id host_id execution_phase profile_digest project_id ticket_id
                        candidate_version repository_fingerprint]
          return false unless required.all? { |key| selection[key].is_a?(String) && selection[key].present? }
          return false unless Agents::PhaseProfile.known?(selection[:execution_phase])
          return false unless selection[:profile_digest].length == 64
          return false unless selection.key?(:estimated_cost)

          cost = selection[:estimated_cost]
          cost.nil? || (cost.is_a?(String) && Agents::Limits::Cost.dump(cost) == cost)
        end

        def repository_fingerprint(repository)
          Digest::SHA256.hexdigest(
            [ repository.id, repository.project_id, repository.repo_id, repository.full_name,
              repository.default_branch, repository.updated_at.iso8601(6) ].join("\0")
          )
        end

        # La versione riguarda i contenuti operativi dello snapshot, non soltanto la riga ticket.
        # I nomi account e i metadati display della milestone sono esclusi: le rispettive identità
        # restano legate dalle FK del ticket/commento, senza introdurre lock inversi su dati cosmetici.
        def candidate_version(ticket)
          snapshot = operational_snapshot(AgentTicketCandidateSerializer.new(ticket).as_json.deep_stringify_keys)
          Digest::SHA256.hexdigest(JSON.generate(canonical(snapshot)))
        end

        private

        def payload(ticket:, host:, execution_phase:, repository:, estimated_cost:)
          profile = Agents::PhaseProfile.fetch(execution_phase)
          {
            version: VERSION,
            organization_id: ticket.project.organization_id,
            host_id: host.id,
            execution_phase: profile.phase,
            profile_digest: profile.digest,
            project_id: ticket.project_id,
            ticket_id: ticket.id,
            estimated_cost:,
            candidate_version: candidate_version(ticket),
            repository_fingerprint: repository_fingerprint(repository)
          }
        end

        def canonical(value)
          case value
          when Hash
            value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |item| canonical(item) }
          when Array
            value.map { |item| canonical(item) }
          else
            value.as_json
          end
        end

        def operational_snapshot(snapshot)
          %w[assignee reporter reviewer milestone].each do |key|
            snapshot[key] = snapshot[key]&.slice("id")
          end
          snapshot.fetch("comments", []).each do |comment|
            comment["author"] = comment.fetch("author").slice("id")
          end
          snapshot
        end

        def verifier = Rails.application.message_verifier(:agent_ticket_queue_selection)
      end
    end
  end
end
