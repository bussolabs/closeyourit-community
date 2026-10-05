# frozen_string_literal: true

module Valhalla
  # Pannello god (cross-tenant). Richiede autenticazione (da ApplicationController) + ruolo god.
  class BaseController < ApplicationController
    include Listable
    # CYRA-694 — inerte finché un controller non dichiara `remembers_filters`.
    include RememberableFilters
    include Localizable
    include ModalForms

    layout -> { modal_form_request? ? "member_modal" : "valhalla" }

    before_action :require_god!

    private

    def require_god!
      # Current.account è garantito da require_authentication (precede questo guard). Il ramo non-god è
      # RAGGIUNGIBILE (un utente autenticato non-god che tenta Valhalla) e coperto da spec (FIX-F).
      unless Current.account.god?
        Rails.logger.warn(
          "Unauthorized Valhalla access attempt account_id=#{Current.account.id} path=#{request.path}"
        )
        return redirect_to(root_path, alert: t("valhalla.unauthorized"))
      end

      # Il god DEVE avere il 2FA attivo E la sessione corrente deve aver superato il secondo fattore per
      # operare in Valhalla (CYRA-170 FIX-5). Il gate condiviso (Authentication) manda all'enrollment se il
      # 2FA non è attivo, o termina+rimanda al login se la sessione non è verificata (sessione pre-2FA
      # sopravvissuta). Il ruolo god è del true_account (cross-tenant), come il 2FA.
      require_god_two_factor!
    end
  end
end
