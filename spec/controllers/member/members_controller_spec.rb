# frozen_string_literal: true

require "rails_helper"

# Unit test dei rami difensivi di Member::MembersController non raggiungibili via request spec
# (Current.account/organization sono sempre presenti nell'area member autenticata): il warn di
# forbid_protected_target! usa safe-nav su Current.* → qui esercitiamo i rami else (nil).
RSpec.describe Member::MembersController do
  subject(:controller) do
    ctrl = described_class.new
    ctrl.set_request!(ActionDispatch::TestRequest.create)
    ctrl.set_response!(described_class.make_response!(ctrl.request))
    ctrl
  end

  after { Current.reset }

  describe "#forbid_protected_target!" do
    it "logga e reindirizza su target protetto con Current vuoto (safe-nav else su account/org)" do
      Current.account = nil
      Current.organization = nil
      allow(controller).to receive(:actor_privileged?).and_return(false)
      target = instance_double(Connections::Membership, owner?: true, id: "tid")
      allow(controller).to receive(:scoped_membership).and_return(target)

      controller.send(:forbid_protected_target!)

      expect(controller.response).to be_redirect
    end
  end
end
