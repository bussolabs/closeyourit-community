# frozen_string_literal: true

module Website
  class AccessRequestsController < BaseController
    include MarketingGate

    def new
      @website_page = :access_request
      @access_request = AccessRequest.new(locale: I18n.locale.to_s)
    end

    def create
      @website_page = :access_request
      @access_request = AccessRequest.new(access_request_params.merge(locale: I18n.locale.to_s))
      if @access_request.save
        redirect_to view_context.website_page_path(:access_request, sent: "1"), status: :see_other
      else
        render :new, status: :unprocessable_content
      end
    end

    private

    def access_request_params
      params.expect(website_access_request: %i[name email team context])
    end
  end
end
