# frozen_string_literal: true

# Size of a request body, checked before anything reads it whole (CYRA-1124). A declared Content-Length
# is trusted; a chunked body or one without a length is measured by reading at most limit + 1 bytes.
module RequestBodyLimit
  extend ActiveSupport::Concern

  private

  def request_body_over?(limit)
    declared = request.get_header("CONTENT_LENGTH")
    return declared.to_i > limit if declared.present? && !request.has_header?("HTTP_TRANSFER_ENCODING")

    received_body_bytes(limit) > limit
  end

  # Not request.content_length: with Transfer-Encoding it reads the whole body into memory. The bytes
  # read are put back, by rewinding or, on a one-pass input, by handing the controller a copy.
  def received_body_bytes(limit)
    input = request.body_stream
    return 0 if input.nil?

    input.rewind if input.respond_to?(:rewind)
    data = input.read(limit + 1).to_s
    input.respond_to?(:rewind) ? input.rewind : request.set_header("rack.input", StringIO.new(data))
    data.bytesize
  end
end
