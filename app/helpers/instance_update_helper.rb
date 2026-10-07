# frozen_string_literal: true

# CYRA-1035 — the update of a community install, for the god only; nil when there is nothing to say.
module InstanceUpdateHelper
  def instance_update_notice
    return unless Current.account&.god? && App::SelfHosted.enabled?

    @instance_update ||= Instance::Update.new
    @instance_update if @instance_update.available || @instance_update.state
  end
end
