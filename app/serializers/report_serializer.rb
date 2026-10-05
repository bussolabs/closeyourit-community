# frozen_string_literal: true

# Resoconto di lavorazione di un ticket per la CLI. `author` è il nome congelato al momento della
# scrittura (author_name), non quello letto dall'account: una versione è uno snapshot, e resta fedele
# anche se l'account viene cancellato. Fallback all'account per le righe scritte prima dello snapshot.
class ReportSerializer < ApplicationSerializer
  attributes :id, :ticket_id, :version, :body, :source, :created_at

  attribute(:author) { |report| report.author_name.presence || report.author&.name }
end
