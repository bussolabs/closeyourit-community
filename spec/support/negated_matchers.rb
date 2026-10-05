# frozen_string_literal: true

# Negati componibili: servono nelle catene `.and` (`expect { }.to not_change(...).and ...`),
# dove il `not_to` di RSpec non può entrare.
RSpec::Matchers.define_negated_matcher :not_change, :change
