# frozen_string_literal: true

module Member
  module Home
    # Annulla in un colpo tutte le lavorazioni automatiche aperte dell'organizzazione (CYRA-867). Solo
    # owner e admin, come l'annullamento singolo; il lavoro lo fa un job, perché possono essere centinaia.
    class WorkflowCancellationsController < Member::BaseController
      permission_not_required "Non è un permesso del catalogo: decide il ruolo owner o admin, come in " \
                              "Agents::Workflows::Cancel."

      def create
        return redirect_to(member_home_approvals_path, alert: t("member.forbidden")) unless allowed?

        count = open_count
        ::Agents::CancelAllWorkflowsJob.perform_later(current_organization.id, Current.account.id,
                                                      t("member.approvals.cancel_all.reason"))
        redirect_to member_home_approvals_path, notice: t("member.approvals.cancel_all.started", count: count)
      end

      private

      def allowed? = current_membership&.role.in?(%w[admin owner])

      def open_count
        ::Agents::Workflow.joins(ticket: :project)
                          .where(projects: { organization_id: current_organization.id }, cancelled_at: nil, completed_at: nil)
                          .count
      end
    end
  end
end
