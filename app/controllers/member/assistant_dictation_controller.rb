# frozen_string_literal: true

module Member
  # Dictation into a text field: the recording comes in, its text goes back. Nothing is stored.
  class AssistantDictationController < Member::BaseController
    permission_not_required "Transcribes the caller's own recording and returns it to them: no record is read or written."

    def create
      result = Assistant::Dictate.call(audio: params[:audio])
      return render(json: { text: result.value }) if result.ok?

      render plain: result.error.message, status: result.error.status
    end
  end
end
