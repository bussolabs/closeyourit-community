# frozen_string_literal: true

require "rails_helper"

# Il concern Authentication è incluso in ApplicationController; qui copriamo l'helper `authenticated?`
# (usato dalle view) in isolamento — delega a resume_session e ne propaga l'esito.
RSpec.describe Authentication do
  subject(:controller) { ApplicationController.new }

  describe "#authenticated?" do
    it "delega a resume_session e ritorna la sessione quando presente (truthy)" do
      session = instance_double(Accounts::Session)
      allow(controller).to receive(:resume_session).and_return(session)

      expect(controller.send(:authenticated?)).to eq(session)
    end

    it "ritorna nil quando non c'è sessione (resume_session → nil)" do
      allow(controller).to receive(:resume_session).and_return(nil)

      expect(controller.send(:authenticated?)).to be_nil
    end
  end
end
