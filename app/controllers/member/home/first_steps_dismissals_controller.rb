# frozen_string_literal: true

module Member
  module Home
    # Closes the first-steps list of the Home for the whole organization (CYRA-1159). Owner and admin
    # only, because it hides the list from every colleague.
    class FirstStepsDismissalsController < Member::BaseController
      permission_not_required "Non è un permesso del catalogo: decide il ruolo owner o admin, perché la " \
                              "lista si chiude per tutta l'organizzazione."

      # The button names the organization whose Home drew it: after a switch in another tab the session
      # points elsewhere, and closing that other organization's list would be a click nobody made.
      def create
        unless ::Organizations::FirstSteps::Checklist.dismissable_by?(current_membership) &&
               params[:organization_id] == current_organization.id
          return redirect_to(root_path, alert: t("member.forbidden"))
        end

        # One guarded write on this organization only: no validation of unrelated fields, the first day kept.
        ::Organizations::Organization.where(id: current_organization.id, first_steps_dismissed_at: nil)
                                     .update_all(first_steps_dismissed_at: Time.current)
        redirect_to root_path, notice: t("member.home.first_steps.dismissed")
      end
    end
  end
end
