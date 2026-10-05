# frozen_string_literal: true

module Ui
  # Right-hand column of the help assistant, rendered once in the member layout and kept across Turbo
  # visits. The body (conversation + composer) is a turbo-frame that Stimulus ui--assistant loads from
  # member_assistant_panel_path on the FIRST opening: no cost on every page (CYRA-558). The trigger is
  # the AI button of the topbar.
  class AssistantComponent < BaseComponent
  end
end
