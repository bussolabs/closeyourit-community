# frozen_string_literal: true

module Member
  # Tab "Telegram" delle impostazioni account: mostra lo stato di collegamento del Telegram PERSONALE
  # (guida/connetti se scollegato, Scollega se collegato) e lo scollega. Non gated: ognuno gestisce il
  # proprio. Il collegamento avviene invece via webhook /start (Telegram::LinkAccount).
  class TelegramConnectionsController < Member::BaseController
    permission_not_required "Collegamento Telegram personale: ognuno gestisce il proprio."

    # Conia un codice corto monouso per il deep-link /start (solo se il bot è configurato): è ciò che
    # entra nel parametro `start` di Telegram, dove il token firmato non ci starebbe (238 char > 64).
    def show
      return if Settings::Integrations.value(:telegram_bot_username).blank?

      @telegram_start_code = ::Accounts::TelegramLinkCode.issue(account: Current.account)
      load_group if current_membership&.owner?
    end

    def destroy
      Current.account.update!(telegram_chat_id: nil, telegram_username: nil, telegram_linked_at: nil)
      redirect_to member_telegram_connection_path, notice: t("member.notifications.telegram.disconnected")
    end

    private

    # Il gruppo con argomenti è dell'owner (CYRA-852): il codice porta l'organizzazione da collegare.
    def load_group
      @telegram_group = ::Alerting::TelegramGroup.find_by(organization: Current.organization)
      @telegram_group_code = ::Accounts::TelegramLinkCode.issue(account: Current.account, organization: Current.organization)
    end
  end
end
