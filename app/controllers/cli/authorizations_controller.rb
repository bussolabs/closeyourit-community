# frozen_string_literal: true

module Cli
  # Approvazione browser del device-flow (umano loggato). Mostra il client + un selettore tra le org
  # dell'account; on-approve registra la scelta nel grant. Il SEGRETO non passa mai di qui: lo riceve
  # solo la CLI al poll. Eredita da ApplicationController → login richiesto (redirect a /login se assente).
  class AuthorizationsController < ApplicationController
    include Localizable

    layout "auth"

    def show
      @grant = find_live_grant(params[:user_code])
      @organizations = account_organizations
      render status: (@grant ? :ok : :not_found)
    end

    def approve
      @grant = find_grant(params[:user_code])
      return render_show(:not_found) if @grant.nil?

      organization = account_organizations.find_by(id: params[:organization_id])
      if organization.nil?
        flash.now[:alert] = t("cli.authorize.errors.no_organization")
        return render_show(:unprocessable_content)
      end

      if already_authorized_for?(organization)
        @organization = organization
        return render :approved
      end
      return render_unknown unless @grant.approvable?

      result = Accounts::Devices::Approve.call(grant: @grant, account: Current.account, organization:)
      if result.ok?
        @organization = organization
        render :approved
      else
        flash.now[:alert] = result.error.message
        render_show(:unprocessable_content)
      end
    end

    def deny
      grant = find_live_grant(params[:user_code])
      Accounts::Devices::Deny.call(grant:) if grant
      render :denied
    end

    private

    def render_show(status)
      @organizations = account_organizations
      render :show, status: status
    end

    def render_unknown
      @grant = nil
      render_show(:not_found)
    end

    def account_organizations
      Current.account.organizations.order(:name)
    end

    def find_live_grant(user_code)
      return nil if user_code.blank?

      Accounts::DeviceGrant.live.find_by(user_code: user_code.to_s.strip.upcase)
    end

    def find_grant(user_code)
      return nil if user_code.blank?

      Accounts::DeviceGrant.find_by(user_code: user_code.to_s.strip.upcase)
    end

    def already_authorized_for?(organization)
      (@grant.approved? || @grant.fulfilled?) &&
        @grant.account_id == Current.account.id && @grant.organization_id == organization.id
    end
  end
end
