# frozen_string_literal: true

module Valhalla
  # "Update now" of a community install (CYRA-1035): leaves the request for the host and reports its
  # state to the page that waits. Not found anywhere else, closeyour.it included.
  class InstanceUpdatesController < BaseController
    before_action :require_self_hosted!

    # Polled while the update runs; it fails while the app restarts, and the page keeps asking.
    def show
      update = Instance::Update.new
      render json: { state: update.state, version: update.current_version }
    end

    def create
      version = Instance::Update.new.request!(actor: Current.account)
      redirect_to valhalla_root_path, notice: t("valhalla.instance_update.requested", version:)
    rescue Instance::Update::NotRequestable, SystemCallError => e
      Rails.logger.warn("Instance update request refused: #{e.class}")
      redirect_to valhalla_root_path, alert: t("valhalla.instance_update.not_requestable")
    end

    private

    def require_self_hosted!
      head :not_found unless App::SelfHosted.enabled?
    end
  end
end
