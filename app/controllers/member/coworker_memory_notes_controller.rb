module Member
  # The owner accepts, dismisses or removes what a Puck asked to remember (CYRA-1012).
  class CoworkerMemoryNotesController < BaseController
    include CoworkerScoped
    before_action :require_coworker_manager
    permission_not_required "Own Puck: notes only shape the owner's own Puck (CYRA-1012)"

    def update
      note = coworker_puck.memory_notes.find(params[:id])
      note.update!(status: params.require(:status).presence_in(%w[active dismissed]) || note.status)
      back_to_panel("memory")
    end
  end
end
