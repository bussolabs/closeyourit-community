# frozen_string_literal: true

module Member
  # Scollega il gruppo Telegram con argomenti dell'organizzazione (CYRA-852). Solo l'owner: è lui che
  # lo collega e che riceve lì i suoi avvisi. Il collegamento avviene dal bot (Telegram::LinkGroup).
  class TelegramGroupsController < Member::BaseController
    permission_not_required "Non è un permesso del catalogo: decide il ruolo di owner, controllato nell'azione."

    def destroy
      return redirect_to(root_path, alert: t("member.forbidden")) unless current_membership&.owner?

      ::Alerting::TelegramGroup.where(organization: Current.organization).destroy_all
      redirect_to member_telegram_connection_path, notice: t("member.notifications.telegram.group.disconnected")
    end
  end
end
