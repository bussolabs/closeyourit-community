module Member
  # The Puckies this person can see, as characters in a 3D office (CYRA-1283).
  class CoworkerOfficeController < BaseController
    include CoworkerScoped
    permission_not_required "Shows only Puckies the viewer can already open (CYRA-1283)"

    def index
      @puckies = visible.coworker_puckies.order(:name).to_a
      connected_ids = Coworkers::Connection.where(puck_id: @puckies.map(&:id)).distinct.pluck(:puck_id)
      @office_rooms = Coworkers::Office::Rooms.active_for(@puckies, connected_puck_ids: connected_ids)
      @latest_runs = Coworkers::Run.latest_by_puck(@puckies.map(&:id))
    end
  end
end
