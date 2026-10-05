# frozen_string_literal: true

module Ticketing
  # Fotografa la Guidance risolta del progetto del ticket in un Ticketing::WorkContextSnapshot immutabile
  # al momento della presa in carico (CYRA-76). Va chiamato DENTRO la transazione del flusso di claim,
  # DOPO l'acquisizione del lease: o claim + snapshot o niente.
  #
  # Idempotente per ticket: una sola riga esiste (indice unico su ticket_id), quindi un secondo claim —
  # o un replay dello stesso claim — trova lo snapshot già scritto e non lo duplica né lo altera
  # (Scenario 2, "claim concorrenti non duplicano"). Guidance::Resolve gira SOLO alla prima creazione
  # (dentro il block): un claim tardivo cattura così la guidance CORRENTE, senza freeze alla creazione
  # del ticket (Scenario 3).
  #
  # Ritorna lo snapshot (NON un Result): è un helper interno chiamato da un altro service, come
  # Ticketing::RecordActivity. Se la creazione solleva (bug), l'eccezione propaga e la transazione del
  # chiamante fa rollback.
  class CaptureWorkContext < ApplicationService
    def initialize(ticket:, actor: nil)
      @ticket = ticket
      @actor = actor
    end

    def call
      snapshot = Ticketing::WorkContextSnapshot.find_or_create_by!(ticket: @ticket) do |record|
        payload = build_payload
        record.organization_id = @ticket.project.organization_id
        record.actor = @actor
        record.actor_name = @actor&.name
        record.payload = payload
        record.payload_version = Ticketing::Constants::WORK_CONTEXT_PAYLOAD_VERSION
        record.digest = Ticketing::WorkContextSnapshot.compute_digest(payload)
        record.generated_at = Time.current
      end
      # L'evento timeline si scrive SOLO alla prima cattura: i claim/replay successivi trovano lo
      # snapshot e non devono ri-annunciarlo.
      record_capture_event(snapshot) if snapshot.previously_new_record?
      snapshot
    end

    private

    # references + procedures risolte, nella stessa forma di Guidance::ResolutionSerializer (Data#to_h
    # con chiavi stringa → jsonb-safe). Già ordinate deterministicamente da Guidance::Resolve, quindi la
    # serializzazione — e con essa il digest — è stabile.
    def build_payload
      resolution = ::Guidance::Resolve.call(project: @ticket.project)
      {
        "references" => resolution.references.map { |reference| reference.to_h.deep_stringify_keys },
        "procedures" => resolution.procedures.map { |procedure| procedure.to_h.deep_stringify_keys }
      }
    end

    # Evento SINTETICO: solo metadati (digest, versione, conteggi), mai il contenuto delle istruzioni.
    def record_capture_event(snapshot)
      Ticketing::RecordActivity.call(
        ticket: @ticket,
        action: "work_context_captured",
        actor: @actor,
        data: {
          payload_version: snapshot.payload_version,
          digest: snapshot.digest,
          references_count: snapshot.payload.fetch("references").length,
          procedures_count: snapshot.payload.fetch("procedures").length
        }
      )
    end
  end
end
