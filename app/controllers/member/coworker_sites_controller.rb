module Member
  # Sites a Puck may open in its browser, with the login it types for the person (CYRA-1015).
  class CoworkerSitesController < BaseController
    include CoworkerScoped
    before_action :require_coworker_manager
    permission_not_required "Own Puck: a site login only serves the owner's Puck (CYRA-1015)"

    def create
      coworker_puck.sites.create!(params.require(:site).permit(:domain, :username, :password))
      back
    rescue ActiveRecord::RecordInvalid
      back(alert: t("member.coworkers.invalid"))
    end

    def destroy
      coworker_puck.sites.find(params[:id]).destroy!
      back
    end

    private

    def back(**options) = redirect_to(member_coworker_path(coworker_puck, panel: "rules"), status: :see_other, **options)
  end
end
