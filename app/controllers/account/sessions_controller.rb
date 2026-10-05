# frozen_string_literal: true

module Account
  # Gli accessi attivi del proprio account (CYRA-643): un elenco dei browser in cui si è entrati e il
  # gesto per chiuderne uno o tutti gli altri. Prima esisteva solo la via nucleare — cambiare la
  # password, che butta giù ogni sessione — e chi si accorgeva di aver lasciato l'accesso aperto su un
  # computer altrui doveva disturbare tutti i propri dispositivi per rimediare.
  #
  # Area account (login richiesto, nessun contesto org) come l'enrollment 2FA e i token CLI: le
  # sessioni sono dell'ACCOUNT, non di un'organizzazione, e la pagina deve aprirsi anche per il god
  # che in produzione non ha membership.
  class SessionsController < ApplicationController
    include Localizable
    include Sortable

    layout "account"

    # Le sessioni si contano SEMPRE sul true_account, mai su Current.account: durante
    # un'impersonation Current.account è la persona impersonata, e questa pagina ne elencherebbe —
    # e ne chiuderebbe — gli accessi mentre il god crede di guardare i propri. Fuori
    # dall'impersonation i due coincidono. Stesso principio di Account::TwoFactorController.
    before_action :set_owner

    # CYRA-924 — every column but the actions sorts (C9); a person has a handful of sessions.
    SORT_COLUMNS = {
      "device" => ->(session) { session.device_label.to_s.downcase },
      "address" => ->(session) { session.ip_address.presence },
      "last_active" => ->(session) { session.last_active_at },
      "signed_in" => ->(session) { session.created_at }
    }.freeze

    def index
      @sessions = sorted_rows(@owner.sessions.active.order(last_active_at: :desc).to_a, columns: SORT_COLUMNS)
      @current_session_id = Current.session.id
    end

    # Chiude UNA sessione. Due esiti diversi per due casi diversi: la sessione di un altro account non
    # esiste per chi chiede (404 anti-BOLA, mai un 403 che ne confermerebbe l'esistenza), mentre la
    # sessione DA CUI si sta chiedendo esiste eccome — negarla con un 404 sarebbe una bugia. Quella si
    # chiude uscendo, e la pagina lo dice.
    def destroy
      record = @owner.sessions.find(params[:id])

      if record.id == Current.session.id
        return redirect_to account_sessions_path, alert: t("account.sessions.cannot_revoke_current")
      end

      record.destroy!
      redirect_to account_sessions_path, notice: t("account.sessions.revoked")
    end

    # Chiude tutte le altre e tiene solo quella in uso: è il gesto di chi ha perso un dispositivo e non
    # sa più quali accessi siano aperti. Chi lo esegue resta dentro — dover rifare l'accesso dopo aver
    # messo in sicurezza il proprio account è la ragione per cui si rimanda a domani.
    def destroy_others
      count = @owner.sessions.where.not(id: Current.session.id).destroy_all.size
      redirect_to account_sessions_path, notice: t("account.sessions.revoked_others", count: count)
    end

    private

    def set_owner
      @owner = Current.true_account
    end
  end
end
