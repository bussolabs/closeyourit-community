# frozen_string_literal: true

# CYRA-933 — a New asked for by the modal gets its form alone, inside the "modal" frame.
module ModalForms
  extend ActiveSupport::Concern

  MODAL_FRAMES = %w[modal modal_stack].freeze

  included do
    helper_method :modal_form_request?
  end

  private

  # Only the form actions answer in the modal: after a save the redirect lands on a full page, the
  # frame is missing from it and the browser leaves the modal for that page.
  def modal_form_request?
    MODAL_FRAMES.include?(turbo_frame_request_id) && %w[new create].include?(action_name)
  end
end
