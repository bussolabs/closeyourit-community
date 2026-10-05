# frozen_string_literal: true

module Member
  module MeasurementReading
    extend ActiveSupport::Concern
    include OtlpReadBudget

    included do
      rescue_from ::Measurements::Series::Query::Invalid, ::Measurements::Aggregation::Query::Invalid, OtlpReadBudget::Exceeded, with: :measurement_query_error
    end

    private

    def measurement_scope
      ::Measurements::Series.where(project_id: visible.projects.select(:id))
    end

    def measurement_page(template = action_name, status: :ok)
      content = render_to_string(template: "#{controller_path}/#{template}", layout: "member")
      raise OtlpReadBudget::Exceeded if content.bytesize > OtlpReadBudget::MAX_RESPONSE_BYTES
      render html: content.html_safe, layout: false, status: status
    end

    def measurement_query_error(_error)
      render "member/monitoring/measurements/query_error", status: :unprocessable_content
    end

    def page_records(scope)
      Pagination.from_query(total: scope.count, page: params[:page], per: requested_per(Pagination::DEFAULT_PER)) do |offset, limit|
        bounded_records(scope.offset(offset).limit(limit))
      end
    end
  end
end
