# frozen_string_literal: true

class ErrorGroupSerializer < ApplicationSerializer
  # resolution_cause/fix (CYRA-192): perché l'errore c'era e cosa l'ha chiuso. Escono anche in lista
  # e non solo nella show — chi scorre `cyi errors list` deve vedere subito quali risoluzioni sono
  # spiegate e quali no, che è metà del motivo per cui i campi esistono.
  attributes :id, :fingerprint, :title, :culprit, :release,
             :events_count, :users_count, :first_seen_at, :last_seen_at, :ticket_id,
             :resolution_cause, :resolution_fix

  attribute(:level) { |g| g.level }
  attribute(:status) { |g| g.status }
  attribute(:promoted) { |g| g.promoted? }
  # CYRA-153: assegnatario (id + nome) o null. Chi lista/ispeziona da `cyi` vede subito di chi è in
  # carico l'errore. Preloadare :assignee a monte evita l'N+1 in lista.
  attribute(:assignee) { |g| g.assignee && { id: g.assignee.id, name: g.assignee.name } }
end
