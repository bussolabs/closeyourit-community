# frozen_string_literal: true

# Helper per i test sugli embedding: vettori deterministici a dimensione reale (1024).
#
# `basis_vector(i)` = versore con 1.0 all'indice i → la distanza coseno tra basi diverse è
# esattamente 1.0, tra basi uguali 0.0: ranking prevedibili senza numeri magici nei test.
# `blend_vector(i, j, weight:)` = combinazione normalizzata di due basi → distanze intermedie
# controllabili (più weight su i ⇒ più vicino a basis_vector(i)).
module EmbeddingsHelpers
  def basis_vector(index)
    Array.new(Ai::Constants::EMBEDDING_DIMENSIONS, 0.0).tap { |v| v[index] = 1.0 }
  end

  def blend_vector(index_a, index_b, weight: 0.9)
    other = Math.sqrt(1.0 - (weight**2))
    Array.new(Ai::Constants::EMBEDDING_DIMENSIONS, 0.0).tap do |v|
      v[index_a] = weight
      v[index_b] = other
    end
  end
end

RSpec.configure do |config|
  config.include EmbeddingsHelpers
end
