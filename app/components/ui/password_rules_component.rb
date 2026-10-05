# frozen_string_literal: true

module Ui
  # Checklist delle regole password (min 8 + 4 classi). Stato live via Stimulus ui--password-rules:
  # va racchiusa, insieme all'input password, in un elemento `data-controller="ui--password-rules"`.
  class PasswordRulesComponent < BaseComponent
    RULES = %i[length uppercase lowercase number special].freeze

    def initialize(test_id: nil, **options)
      @test_id = test_id
      @options = options
    end

    private

    def rules
      RULES
    end

    # aria-live="polite": ogni regola aggiorna il proprio stato testuale (vedi ui--password-rules)
    # mentre l'utente digita — lo screen reader annuncia i cambi senza spostare il focus.
    def html_options
      merge_options(base_class: "mt-2 space-y-1 text-[11px]", test_id: @test_id, options: @options)
        .merge(aria: { live: "polite" })
    end
  end
end
