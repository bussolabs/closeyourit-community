# frozen_string_literal: true

# Riga permanente «Come proteggiamo questi segreti» (CYRA-422): cifratura a riposo, tracciamento delle
# letture e retention del registro, SEMPRE nel corpo — non più solo dentro un suggerimento a scomparsa.
# Resa in fondo a tutte le pagine dei segreti (personali, di progetto, dell'organizzazione, e i rispettivi
# file). Il testo di cifratura cambia col `kind`; tracciamento e retention sono comuni. Nessuna query:
# afferma solo ciò che il prodotto applica davvero (registro append-only, mai potato — CYRA-422).
class SecretProtectionComponent < Ui::BaseComponent
  KINDS = %i[personal personal_files project project_files shared shared_files].freeze

  def initialize(kind:, test_id: "secret-protection")
    @kind = kind.to_sym
    @test_id = test_id

    raise ArgumentError, "kind sconosciuto: #{@kind}" unless KINDS.include?(@kind)
  end

  private

  attr_reader :kind, :test_id
end
