# frozen_string_literal: true

# Uploads use authenticated application endpoints, never the public engine endpoint.
module DisabledDirectUploads
  def create
    head :not_found
  end
end
