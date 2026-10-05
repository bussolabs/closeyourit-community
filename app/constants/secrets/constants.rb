# frozen_string_literal: true

module Secrets
  # Costanti del dominio vault (rules/constants.md). I VALORI dei segreti non stanno mai qui: qui
  # stanno solo le regole con cui si guarda la loro età.
  module Constants
    # Rotazione "morbida" dei secret (CYRA-138). Un secret può avere una policy
    # rotation_interval_days ("ruota ogni N giorni", Secrets::Variable); la scadenza calcolata
    # (rotate_by) è SOLO un avviso — non blocca mai la lettura (Secrets::Bundle invariato). Questa è
    # la soglia di preavviso: entro N giorni da rotate_by lo stato passa da :ok a :due_soon.
    ROTATION_DUE_SOON_DAYS = 14
  end
end
