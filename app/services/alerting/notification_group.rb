# frozen_string_literal: true

module Alerting
  # Riga display del notification center (CYRA-323): raccoglie avvisi IDENTICI (stesso subject, evento,
  # titolo e corpo) ravvicinati entro 60 minuti in un gruppo solo, col conteggio delle ripetizioni.
  # La chiave include il BODY apposta: un peggioramento (es. 27 → 42 container caduti) cambia il testo
  # → chiave diversa → riga nuova, non assorbita silenziosamente nel conteggio precedente.
  # Limitato alla pagina corrente: notifications è già la porzione paginata (ordine :recent, desc).
  class NotificationGroup
    WINDOW = 60.minutes

    attr_reader :notifications

    def self.group(notifications)
      notifications.each_with_object([]) do |notification, groups|
        current = groups.last
        if current&.match?(notification)
          current.add(notification)
        else
          groups << new(notification)
        end
      end
    end

    def initialize(notification)
      @notifications = [ notification ]
    end

    def match?(notification)
      key_for(notification) == key && (representative.created_at - notification.created_at) <= WINDOW
    end

    def add(notification) = @notifications << notification

    def representative = @notifications.first
    def count = @notifications.size
    def repeated? = count > 1
    def ids = @notifications.map(&:id)
    def read? = @notifications.all?(&:read?)

    private

    def key = key_for(representative)

    def key_for(notification)
      [ notification.subject_type, notification.subject_id, notification.event_type,
        notification.title, notification.body ]
    end
  end
end
