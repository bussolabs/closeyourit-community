# frozen_string_literal: true

require "rails_helper"

# Unit test del concern OrganizationContext (incluso in Member::BaseController). Esercita in
# isolamento i rami difficili da raggiungere via request spec: i safe-nav su Current.* quando il
# contesto è vuoto e i fallback `||`. Si usa un'istanza reale del controller con TestRequest/Response.
#
# CYRA-740 — le altre tre parti hanno ciascuna il proprio file: spec/controllers/member/
# permission_gates_spec.rb, spec/controllers/member/visible_resources_spec.rb e
# spec/presenters/navigation/visibility_spec.rb.
RSpec.describe OrganizationContext do
  subject(:controller) do
    ctrl = Member::MembersController.new
    ctrl.set_request!(ActionDispatch::TestRequest.create)
    ctrl.set_response!(Member::MembersController.make_response!(ctrl.request))
    ctrl
  end

  after { Current.reset }

  describe "#projects_view_preference" do
    it "usa la preferenza personale dell'account quando presente" do
      Current.account = create(:account, projects_view: "table")
      Current.organization = nil
      expect(controller.send(:projects_view_preference)).to eq("table")
    end

    it "ricade sul default dell'org quando l'account non ha preferenza" do
      Current.account = create(:account) # projects_view nil
      Current.organization = create(:organization, default_projects_view: "table")
      expect(controller.send(:projects_view_preference)).to eq("table")
    end

    it "ricade su 'cards' quando né account né org hanno una preferenza (|| finale)" do
      Current.account = create(:account)
      Current.organization = create(:organization) # default_projects_view nil
      expect(controller.send(:projects_view_preference)).to eq("cards")
    end

    it "ricade su 'cards' con Current vuoto (safe-nav else su account e org)" do
      Current.account = nil
      Current.organization = nil
      expect(controller.send(:projects_view_preference)).to eq("cards")
    end
  end
end
