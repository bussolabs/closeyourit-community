# frozen_string_literal: true

module Agents
  module Leases
    # Confine condiviso acquire/renew/release: identità del titolare dal token, riferimento ticket
    # tenant-scoped, path/body coerenti e TTL intero positivo.
    class Operation < ApplicationService
      TICKET_REFERENCE = /\A([A-Z0-9]{1,4})-([1-9]\d{0,9})\z/
      MAX_TICKET_NUMBER = 2_147_483_647
      MAX_IDENTIFIER_LENGTH = 255
      MAX_TTL_SECONDS = 30.days.to_i

      def initialize(organization:, holder:, ticket_reference:, params:)
        @organization = organization
        @holder = holder
        @ticket_reference = ticket_reference.to_s
        @params = params.to_h.symbolize_keys
      end

      private

      def prepare(require_ttl: false, require_identity: false, require_scope: false)
        return invalid(:ticket) unless valid_ticket_references?

        holder_validation = validate_holder
        return holder_validation if holder_validation

        return invalid(:run_id) unless valid_identifier?(@params[:run_id])
        return invalid(:execution_phase) if execution_phase_supplied? && !execution_phase_known?
        return invalid(:agent) if require_identity && @holder.host? && !work_identity_present?
        return invalid(:ttl_seconds) if require_ttl && !valid_ttl?

        @ticket = resolve_ticket
        return ticket_not_found unless @ticket
        if require_scope && @holder.host? && !Agents::Hosts::ProjectScope.new(host: @holder.record).allows?(@ticket.project)
          return ticket_not_found
        end

        nil
      end

      # Il canale host dichiara host_id nel body e deve coincidere con l'host autenticato: è la difesa
      # contro il client che punta all'host sbagliato, e va conservata. Il canale account non dichiara
      # nulla — il titolare viene dal token e non è falsificabile — quindi un host_id nel body sarebbe
      # solo un modo per fingersi un altro: si rifiuta.
      def validate_holder
        if @holder.host?
          return invalid(:host_id) unless @params[:host_id].is_a?(String) && @params[:host_id].present?
          return forbidden_host unless @holder.record.organization_id == @organization.id &&
                                       @params[:host_id] == @holder.id

          return nil
        end

        return invalid(:host_id) if @params[:host_id].present?

        forbidden_holder unless account_in_organization?
      end

      def account_in_organization?
        Connections::Membership.exists?(organization_id: @organization.id, account_id: @holder.id)
      end

      # Dual-stack: un lease nasce con un'identità di lavoro — lo slug agent legacy (prompt-mode) OPPURE
      # l'execution_phase host-first. Vietato un lease senza né l'uno né l'altro.
      def work_identity_present?
        valid_identifier?(@params[:agent]) || valid_identifier?(@params[:execution_phase])
      end

      # Se il client fornisce una execution_phase, deve essere una fase nota — validata QUI (fail-fast, prima
      # di lock e write) così una fase sconosciuta ritorna sempre R422-LEASE-001 indipendentemente dallo stato
      # del lease, invece di dipendere dalla validazione del modello a valle di create_or_find_by!.
      def execution_phase_supplied? = @params[:execution_phase].present?

      def execution_phase_known? = Agents::PhaseProfile.known?(@params[:execution_phase])

      # Host-first: il profilo pinnato sul lease diverge dal PhaseProfile corrente della fase (drift dopo un
      # deploy). Condiviso da Renew e Acquire, che devono entrambi fallire chiuso invece di prolungare o
      # adottare un lease il cui lavoro non sarebbe mai consegnabile.
      def profile_drifted?(lease)
        lease.profile_digest.present? &&
          lease.profile_digest != Agents::PhaseProfile.for(lease.execution_phase)&.digest
      end

      # Host-first: la richiesta dichiara una execution_phase diversa da quella pinnata sul lease attivo. Un
      # run possiede una sola fase — Acquire e Renew rifiutano il mismatch invece di adottare o prolungare un
      # lavoro che la delivery non potrebbe mai accettare.
      def phase_mismatch?(lease)
        supplied = @params[:execution_phase].presence
        lease.execution_phase.present? && supplied.present? && lease.execution_phase != supplied
      end

      def valid_ticket_references?
        path = canonical_ticket(@ticket_reference)
        body = canonical_ticket(@params[:ticket])
        path.present? && body.present? && path == body
      end

      def canonical_ticket(value)
        normalized = value.to_s.strip.upcase
        match = TICKET_REFERENCE.match(normalized)
        normalized if match && match[2].to_i <= MAX_TICKET_NUMBER
      end

      def resolve_ticket
        match = TICKET_REFERENCE.match(canonical_ticket(@ticket_reference))
        project = @organization.projects.find_by(key: match[1])
        project&.tickets&.find_by(number: match[2].to_i)
      end

      def valid_identifier?(value)
        value.is_a?(String) && value.present? && value.length <= MAX_IDENTIFIER_LENGTH
      end

      def valid_ttl?
        @params[:ttl_seconds].is_a?(Integer) && @params[:ttl_seconds].between?(1, MAX_TTL_SECONDS)
      end

      # I lease prendono il suffisso host → ticket → lease dell'ordine globale del dispatch. Non
      # bloccano organization/policy: le FK organization prendono lock compatibili e nessun writer
      # che possiede host/ticket deve poi risalire nella gerarchia. Il ticket chiude anche la race revoke.
      #
      # Un titolare account non ha una riga host da bloccare: l'ordine diventa ticket → lease, che è un
      # SUFFISSO dello stesso ordine globale — nessun ciclo, quindi nessun deadlock con i writer host.
      # Non esiste l'equivalente della revoca: l'appartenenza all'organizzazione è già verificata in
      # prepare e il permesso RBAC nel controller.
      def lock_active_holder
        return true if @holder.account?

        @holder.record.lock!
        !@holder.record.revoked?
      rescue ActiveRecord::RecordNotFound
        false
      end

      def lock_ticket
        @ticket.lock!
      rescue ActiveRecord::RecordNotFound
        nil
      end

      # Chi tiene il ticket, nel corpo del 409: il client deve poterlo dire all'utente senza una seconda
      # chiamata. `held_by` porta il nome leggibile perché il perdente può essere una persona.
      def holder_payload(lease)
        {
          ticket: lease.ticket.code,
          host_id: lease.host_id,
          account_id: lease.account_id,
          held_by: { kind: lease.holder_kind, id: lease.holder_id, name: holder_name(lease) },
          run_id: lease.run_id,
          agent: lease.agent,
          execution_phase: lease.execution_phase,
          expires_at: lease.expires_at
        }
      end

      def holder_name(lease) = lease.human? ? lease.account&.name : lease.host&.hostname

      def conflict(lease)
        Result.err(
          AppError.new(
            "Ticket già detenuto da un'altra lavorazione",
            code: "R409-LEASE-001",
            status: :conflict,
            details: { holder: holder_payload(lease) }
          )
        )
      end

      # Host-first: lo stesso run possiede il lease ma per un'altra fase (il pin è immutabile per la vita
      # del lease). Il claim non può adottarlo per la nuova fase — va rilasciato prima.
      def phase_conflict(lease)
        Result.err(
          AppError.new(
            "Il run possiede già il lease del ticket per un'altra fase",
            code: "R409-LEASE-006",
            status: :conflict,
            details: { pinned_execution_phase: lease.execution_phase }
          )
        )
      end

      def released_acquisition
        Result.err(
          AppError.new(
            "Questa lavorazione ha già rilasciato il ticket",
            code: "R409-LEASE-002",
            status: :conflict
          )
        )
      end

      def tombstoned?
        Agents::Leases::Tombstone.exists?(
          { ticket: @ticket, run_id: @params[:run_id] }.merge(@holder.ownership_attributes)
        )
      end

      def record_tombstone(lease, released_at:)
        Agents::Leases::Tombstone.record!(lease:, released_at:)
      end

      def retire(lease, released_at:)
        record_tombstone(lease, released_at:)
        lease.destroy!
      end

      def invalid(field, errors = nil)
        Result.err(
          AppError.new(
            "Richiesta lease non valida",
            code: "R422-LEASE-001",
            details: errors || { field => [ I18n.t("errors.messages.invalid") ] }
          )
        )
      end

      def forbidden_host
        Result.err(
          AppError.new(
            "L'host autenticato non coincide con host_id",
            code: "R403-LEASE-001",
            status: :forbidden
          )
        )
      end

      # Il token è valido ma l'account non appartiene all'organizzazione del ticket: non può occupare
      # un ticket che non gli è visibile.
      def forbidden_holder
        Result.err(
          AppError.new(
            "L'account autenticato non appartiene all'organizzazione",
            code: "R403-LEASE-002",
            status: :forbidden
          )
        )
      end

      def not_found(code = "R404-LEASE-002", message = "Lease assente o scaduto")
        Result.err(AppError.new(message, code:, status: :not_found))
      end

      def ticket_not_found = not_found("R404-LEASE-001", "Ticket non trovato")

      def lease_unavailable
        Result.err(
          AppError.new(
            "Stato lease modificato ripetutamente; riprovare",
            code: "R503-LEASE-001",
            status: :service_unavailable
          )
        )
      end

      def authoritative_ttl_mismatch(lease)
        Result.err(
          AppError.new(
            "Il TTL richiesto non coincide con il TTL autoritativo del lease",
            code: "R409-LEASE-003",
            status: :conflict,
            details: {
              requested_ttl_seconds: @params[:ttl_seconds],
              expected_ttl_seconds: lease.authoritative_ttl_seconds
            }
          )
        )
      end

      def authoritative_expired
        Result.err(
          AppError.new(
            "La finestra autoritativa del claim è già scaduta",
            code: "R409-LEASE-004",
            status: :conflict
          )
        )
      end

      # Host-first: il profilo pinnato sul lease non coincide più con il PhaseProfile corrente della fase.
      def profile_drift(lease)
        Result.err(
          AppError.new(
            "Il profilo della fase è cambiato dopo la presa del lease",
            code: "R409-LEASE-005",
            status: :conflict,
            details: { execution_phase: lease.execution_phase, pinned_profile_digest: lease.profile_digest }
          )
        )
      end

      def record_invalid(error)
        invalid(:lease, error.record.errors.to_hash)
      end
    end
  end
end
