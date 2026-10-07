module Member
  # Disconnects a person's computer from their Puckies in one click (CYRA-1029).
  class CoworkerDevicesController < BaseController
    include CoworkerScoped
    permission_not_required "Own computer: only its owner sees and disconnects it (CYRA-1029)"

    def destroy
      device = Coworkers::Device.where(account: Current.account, organization: Current.organization).find(params[:id])
      device.update!(revoked_at: Time.current)
      device.calls.where(status: %w[pending delivered]).update_all(status: "expired", updated_at: Time.current)
      redirect_to member_coworker_path(coworker_puck, panel: "rules"), status: :see_other
    end
  end
end
