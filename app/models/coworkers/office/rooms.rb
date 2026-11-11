module Coworkers
  module Office
    # Decoration follows saved configuration of visible Puckies, never their names or instructions (CYRA-1283).
    module Rooms
      IDS = %w[archive observatory workshop].freeze

      def self.active_for(puckies, connected_puck_ids: [])
        active = []
        active << "archive" if puckies.any? { |puck| puck.preset.to_s.split("@").first == "researcher" }
        active << "observatory" if puckies.any? { |puck| puck.watch_every_minutes }
        active << "workshop" if puckies.any? { |puck| connected_puck_ids.include?(puck.id) }
        active
      end
    end
  end
end
