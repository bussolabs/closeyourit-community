# frozen_string_literal: true

module Member
  # Cambia l'organizzazione di contesto. Non-god: solo tra le org di cui l'account è membro (anti-BOLA).
  # God: qualsiasi org (accesso cross-tenant nativo, gated su true_account.god?).
  class OrganizationSwitchesController < Member::BaseController
    permission_not_required "Cambia l'organizzazione di contesto: si passa soltanto alle proprie (il god ovunque, " \
                            "per costruzione)."

    # CYRA-722 — l'unica azione dell'area che resta aperta con l'organizzazione sospesa: è la via
    # d'uscita offerta dalla pagina di sospensione. Bloccarla incastrerebbe chi ha anche un'altra
    # organizzazione attiva nell'unica che non può usare.
    skip_before_action :require_active_organization

    # `return_to` lands on a page of the new organization; url_from keeps only local paths (CYRA-879).
    def create
      target =
        if Current.true_account&.god?
          Organizations::Organization.find_by(id: params[:organization_id])
        else
          Current.account.organizations.find_by(id: params[:organization_id])
        end
      if target
        session[:organization_id] = target.id
        session.delete(:space) # lo space è per-sessione e globale: azzerarlo così riparte dal default della nuova org
        redirect_to url_from(params[:return_to]) || root_path, notice: t("member.switched", name: target.name)
      else
        redirect_to root_path, alert: t("member.forbidden")
      end
    end
  end
end
