# frozen_string_literal: true

module Secrets
  # Hub unico per l'audit del vault: crea un Secrets::Event append-only. Fire-and-forget — un audit che
  # fallisce NON deve rompere una lettura/mutazione (rescue + log). Chiamato dai punti di lettura
  # (bundle CLI, tab Member), di mutazione (Set/Delete/Import/Sync) e di RIFIUTO (action "denied":
  # confine ambienti, CYRA-78 — lì `channel:` dice se il tentativo arrivava dal web o dalla CLI).
  class RecordEvent < ApplicationService
    # Azioni che descrivono un ACCESSO ai valori (o un tentativo): sono le uniche su cui può scattare
    # un avviso (CYRA-77). Le mutazioni hanno già i loro (secret_deleted, secret_change_*).
    ALERTABLE_ACTIONS = %w[read denied].freeze

    def initialize(action:, project:, environment: nil, actor: nil, name: nil, metadata: {}, channel: nil)
      @action = action
      @project = project
      @environment = environment
      @actor = actor
      @name = name
      @metadata = metadata
      @channel = channel
    end

    def call
      event = Secrets::Event.create!(
        action: @action,
        project: @project,
        organization: @project.organization,
        environment: @environment,
        actor: @actor,
        name: @name,
        metadata: @metadata,
        channel: @channel
      )
      notify_access(event)
      event
    rescue StandardError => e
      Rails.logger.warn("Secrets audit event failed: #{e.class} #{e.message}")
      nil
    end

    private

    # CYRA-77 — l'accesso a un segreto sensibile fa scattare la pipeline di alerting, ma SOLO dal web.
    # Le letture del terminale sono programmatiche per definizione (`cyi run` legge il vault a ogni
    # avvio di un processo): avvisare su quelle vorrebbe dire spegnere l'attenzione di chi riceve gli
    # avvisi nel giro di un giorno, e allora anche la lettura che conta passerebbe inosservata.
    # `channel` nil (eventi emessi dai service di dominio, che servono entrambi i canali) NON allarma:
    # non sapere da dove arriva una lettura non è una ragione per svegliare qualcuno.
    # Senza una regola attiva nell'org, Evaluate è comunque un no-op.
    def notify_access(event)
      return unless ALERTABLE_ACTIONS.include?(@action.to_s)
      return unless @channel.to_s == "web"

      Alerting::EvaluateJob.perform_later(
        event_type: "secret_#{@action}", subject_type: "Secrets::Event", subject_id: event.id,
        project_id: @project.id, environment_id: @environment&.id
      )
    end
  end
end
