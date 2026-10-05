# frozen_string_literal: true

# Errore di dominio con codice R{STATUS}-{DOMINIO}-{SEQ} (rules/error-handling.md).
class AppError < StandardError
  attr_reader :code, :status, :details

  def initialize(message, code:, status: :unprocessable_content, details: nil)
    super(message)
    @code = code
    @status = status
    @details = details
  end
end
