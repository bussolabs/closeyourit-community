# frozen_string_literal: true

module Ui
  # Menu utente dell'header: `<details>` nativo (apre/chiude senza JS) con le iniziali
  # come trigger; il pannello apre con nome ed email (CYRA-898), poi la voce Account (opzionale, passa
  # `account_path`), l'ingresso Valhalla (opzionale, passa `valhalla_path`: voce
  # corona separata da un divider perché è area god, non un'azione quotidiana —
  # CYRA-331) e l'azione Esci. Riusa le classi-voce di Ui::RowMenuComponent.
  class UserMenuComponent < BaseComponent
    def initialize(name:, logout_path:, email: nil, account_path: nil, account_label: nil,
                   valhalla_path: nil, valhalla_label: nil, valhalla_test_id: nil,
                   logout_label: nil, trigger_test_id: nil, account_test_id: nil,
                   logout_test_id: nil)
      @name = name
      @email = email
      @logout_path = logout_path
      @account_path = account_path
      @account_label = account_label
      @valhalla_path = valhalla_path
      @valhalla_label = valhalla_label
      @valhalla_test_id = valhalla_test_id
      @logout_label = logout_label || I18n.t("home.sign_out")
      @trigger_test_id = trigger_test_id
      @account_test_id = account_test_id
      @logout_test_id = logout_test_id
    end

    private

    def item_class(variant)
      RowMenuComponent.item_class(variant)
    end
  end
end
