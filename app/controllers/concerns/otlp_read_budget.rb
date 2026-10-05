# frozen_string_literal: true

module OtlpReadBudget
  extend ActiveSupport::Concern

  MAX_PRELOAD_BYTES = 5 * 1024 * 1024
  MAX_RESPONSE_BYTES = 1024 * 1024
  Exceeded = Class.new(StandardError)

  included do
    rescue_from Exceeded do
      render_error("R422-OTLP-001", "Requested records exceed the response byte budget", status: :unprocessable_content)
    end
  end

  private

  def paginate_bounded(scope)
    result = Pagination.from_query(total: scope.count, page: params[:page],
      per: params[:per].presence || Pagination::MACHINE_DEFAULT_PER) do |offset, limit|
      bounded_records(scope.offset(offset).limit(limit))
    end
    meta = { page: result.page, per: result.per, total: result.total, total_pages: result.total_pages }
    [ result.records, meta ]
  end

  def bounded_record(scope)
    bounded_records(scope.limit(1)).first || raise(ActiveRecord::RecordNotFound)
  end

  def bounded_records(scope)
    table = scope.klass.quoted_table_name
    primary_key = scope.klass.primary_key
    sizes = scope.pluck(primary_key, Arel.sql("octet_length(to_jsonb(#{table})::text)"))
    raise Exceeded if sizes.sum(&:last) > MAX_PRELOAD_BYTES

    # Keep the measured identities when a concurrent insert changes page offsets.
    scope.except(:offset, :limit).where(primary_key => sizes.map(&:first)).to_a
  end

  def render_bounded(data, meta: nil)
    payload = { data: data.as_json }
    payload[:meta] = meta if meta
    body = payload.to_json
    raise Exceeded if body.bytesize > MAX_RESPONSE_BYTES

    render json: body
  end
end
