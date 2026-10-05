# frozen_string_literal: true

module Github
  module Webhooks
    # Evento `push`: se il ref è un tag (refs/tags/*), tenta il binding tag→release. (Branch → Fase 2.)
    class Push < Base
      def call
        ref = value_at(@payload, "ref").to_s
        return Result.ok(nil) unless ref.start_with?("refs/tags/")

        bind_tag(ref.delete_prefix("refs/tags/"))
      end
    end
  end
end
