# frozen_string_literal: true

module Assistant
  # Mappa i messaggi persistiti di una conversazione nel formato `contents` del client (memoria
  # multi-turno): [{ role: "user"|"model", parts: [{ text: }] }, ...]. Solo i messaggi COMPLETI entrano
  # nel contesto — quelli ancora in streaming o falliti non hanno testo utile. Cap agli ultimi N per non
  # gonfiare il prompt.
  class BuildHistory < ApplicationService
    ROLE_MAP = { "user" => "user", "assistant" => "model" }.freeze

    def initialize(conversation:, until_message: nil, limit: Assistant::Constants::MAX_HISTORY_MESSAGES)
      @conversation = conversation
      @until_message = until_message
      @limit = limit
    end

    def call
      scope = @conversation.messages.status_complete
      # Ferma il contesto al turno corrente: un secondo invio ravvicinato NON deve entrare nella
      # history del job che sta ancora rispondendo al primo (risposte fuori ordine / duplicate).
      scope = scope.where(created_at: ..@until_message.created_at) if @until_message

      mapped = scope.reorder(created_at: :desc, id: :desc).limit(@limit)
                    .reverse_each.map { |m| { role: ROLE_MAP.fetch(m.role), parts: [ { text: m.content } ] } }

      # I `contents` devono iniziare con un turno "user": se il cap ha tagliato la finestra
      # a metà di uno scambio (primo turno "model"), scarta i "model" iniziali per non prendere un 400.
      mapped.shift while mapped.first && mapped.first[:role] == "model"
      mapped
    end
  end
end
