# frozen_string_literal: true

module Member
  module Wikitech
    # Saving a note by hand (CYRA-1130): plain text, its source and links. The cards arrive a moment
    # later, when Wikitech::ProcessNoteJob has read it.
    class NotesController < Member::BaseController
      permission_not_required "Any member of the organization can add external tech knowledge to Wikitech."

      def new; end

      def create
        result = ::Wikitech::SaveNote.call(organization: Current.organization, author: Current.account,
                                           params: note_params)
        if result.err?
          @error = result.error.message
          return render :new, status: :unprocessable_content
        end

        notice = result.value.duplicate ? t("member.wikitech.notes.duplicate") : t("member.wikitech.notes.saved")
        redirect_to member_wikitech_root_path, notice: notice
      end

      private

      # Links come one per line from a textarea.
      def note_params
        permitted = params.permit(:body, :source_label, :source_url, :links)
        permitted.to_h.merge(links: permitted[:links].to_s.split(/\s+/))
      end
    end
  end
end
